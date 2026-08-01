import Foundation
import Security

/// Token storage for the Linear integration.
///
/// The Keychain, never `UserDefaults`: a Linear access token is a live
/// credential to the user's whole workspace, and `UserDefaults` is a
/// world-readable plist inside the container. Nothing here is ever logged —
/// diagnostics dump defaults, and a token in a diagnostics file is a token in
/// a bug report.
enum LinearKeychain {
    private static let service = "com.heyyorick.Yorick.linear"

    /// What we persist between launches. The refresh token is optional
    /// because Linear may issue long-lived access tokens without one; the
    /// client treats "no refresh token" as "reconnect when this expires."
    struct Tokens: Codable, Sendable, Equatable {
        var accessToken: String
        var refreshToken: String?
        /// Absolute expiry, derived from `expires_in` at exchange time.
        /// Nil means the token carries no stated lifetime.
        var expiresAt: Date?

        /// A minute of slack so a token that expires mid-flight refreshes
        /// before the request rather than failing it.
        var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date() >= expiresAt.addingTimeInterval(-60)
        }
    }

    // MARK: - Storage

    static func save(_ tokens: Tokens) throws {
        let data = try JSONEncoder().encode(tokens)
        // Delete-then-add rather than SecItemUpdate: the update path has to
        // branch on whether an item exists, and this has the same end state
        // in one code path.
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        // The token is only ever used while the user is driving the app, so
        // it never needs to be readable before first unlock.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw LinearKeychainError.storeFailed(status) }
    }

    /// Read the token. May present the system keychain dialog if the item's
    /// ACL doesn't trust this binary — so this is ONLY safe to call from an
    /// explicit user action, never from app startup or the dictation path.
    /// See `loadWithoutPrompting` for everywhere else.
    static func load() -> Tokens? {
        load(allowingUI: true)
    }

    /// Read the token, but fail rather than ask.
    ///
    /// The keychain dialog is modal and system-owned. Yorick's whole claim is
    /// that the pill appears at hotkey speed, and the ACL prompt can fire on
    /// ANY read — including one triggered by pressing the hotkey, if the
    /// binary's signature stopped matching the item's ACL (which happens the
    /// moment a build is signed differently). A password sheet on the
    /// dictation path would be a catastrophic version of a papercut, so
    /// nothing on that path is allowed to ask.
    static func loadWithoutPrompting() -> Tokens? {
        load(allowingUI: false)
    }

    private static func load(allowingUI: Bool) -> Tokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowingUI {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    /// Whether a connection exists, WITHOUT reading the secret. Answers the
    /// question the UI and the context gate actually ask ("is Linear set
    /// up?") — the token itself is only needed at request time.
    static func hasStoredTokens() -> Bool {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        // Deliberately no kSecReturnData: metadata reads don't consult the
        // ACL the way a secret read does, so this can't raise a dialog.
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Disconnect. Deliberately infallible from the caller's side: a failed
    /// delete must never strand the user in a connected-looking state they
    /// can't leave, and `errSecItemNotFound` is the desired end state anyway.
    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "tokens",
        ]
    }
}

enum LinearKeychainError: Error, LocalizedError {
    case storeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            return "Could not save the Linear connection to the Keychain (\(status))"
        }
    }
}
