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
    /// One Keychain item holding every workspace's tokens, rather than one
    /// item per workspace: a single ACL means a single authorisation prompt,
    /// and the prompt is the part users hate.
    private static let account = "workspaces"
    /// The pre-multi-workspace item. Read once, lazily, to migrate.
    private static let legacyAccount = "tokens"

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

    /// Every connection, keyed by Linear organization id.
    static func loadAll() -> [String: Tokens] {
        guard let data = read(account: account) else { return [:] }
        return (try? JSONDecoder().decode([String: Tokens].self, from: data)) ?? [:]
    }

    static func load(workspaceID: String) -> Tokens? {
        loadAll()[workspaceID]
    }

    static func save(_ tokens: Tokens, workspaceID: String) throws {
        var all = loadAll()
        all[workspaceID] = tokens
        try writeAll(all)
    }

    static func remove(workspaceID: String) {
        var all = loadAll()
        all.removeValue(forKey: workspaceID)
        if all.isEmpty { clear() } else { try? writeAll(all) }
    }

    /// Whether ANY connection exists, without reading a secret.
    static func hasStoredTokens() -> Bool {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess { return true }
        var legacy = baseQuery(account: legacyAccount)
        legacy[kSecMatchLimit as String] = kSecMatchLimitOne
        legacy[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return SecItemCopyMatching(legacy as CFDictionary, nil) == errSecSuccess
    }

    /// Fold a pre-multi-workspace connection into the keyed store.
    ///
    /// Deliberately LAZY — called from a request the user asked for, never at
    /// launch — because reading the old secret can raise the Keychain dialog,
    /// and a modal at startup is the bug this file already fixed once. The
    /// organization id has to come from the cached mirror, since the legacy
    /// item predates ever recording which workspace it belonged to.
    @discardableResult
    static func migrateLegacy(into workspaceID: String) -> Tokens? {
        guard loadAll().isEmpty, let data = read(account: legacyAccount),
              let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else { return nil }
        try? writeAll([workspaceID: tokens])
        SecItemDelete(baseQuery(account: legacyAccount) as CFDictionary)
        return tokens
    }

    private static func writeAll(_ all: [String: Tokens]) throws {
        let data = try JSONEncoder().encode(all)
        // Delete-then-add rather than SecItemUpdate: the update path has to
        // branch on whether an item exists, and this has the same end state
        // in one code path.
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        // The token is only ever used while the user is driving the app, so
        // it never needs to be readable before first unlock.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw LinearKeychainError.storeFailed(status) }
    }

    /// Reading a SECRET can raise the system Keychain dialog when the item's
    /// ACL doesn't trust this binary, so it happens only inside a request the
    /// user asked for — never at launch, and never on the dictation path. A
    /// modal password sheet triggered by pressing the hotkey would be a
    /// catastrophic version of a papercut.
    private static func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Disconnect. Deliberately infallible from the caller's side: a failed
    /// delete must never strand the user in a connected-looking state they
    /// can't leave, and `errSecItemNotFound` is the desired end state anyway.
    static func clear() {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        SecItemDelete(baseQuery(account: legacyAccount) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
