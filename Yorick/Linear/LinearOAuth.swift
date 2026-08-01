import CryptoKit
import Foundation
import Network

/// PKCE pieces for one authorization attempt. Held only for the duration of
/// the flow — the verifier is a secret that exists to be spent once.
struct PKCEChallenge: Sendable, Equatable {
    let verifier: String
    let challenge: String
    let state: String

    /// RFC 7636: verifier is 43–128 chars of unreserved characters,
    /// challenge is BASE64URL(SHA256(verifier)) with padding stripped.
    init(randomBytes: (Int) -> Data = PKCEChallenge.secureRandom) {
        self.verifier = Self.base64URL(randomBytes(32))
        self.challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        self.state = Self.base64URL(randomBytes(16))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func secureRandom(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        // SecRandomCopyBytes is the only CSPRNG worth using here; a failure
        // is unrecoverable, and falling back to a weak source silently would
        // be worse than crashing.
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed — cannot generate a PKCE verifier")
        }
        return Data(bytes)
    }
}

/// Linear's OAuth endpoints and the URL construction around them. Pure and
/// testable: nothing here touches the network or the Keychain.
enum LinearOAuth {
    static let authorizeURL = URL(string: "https://linear.app/oauth/authorize")!
    static let tokenURL = URL(string: "https://api.linear.app/oauth/token")!
    static let revokeURL = URL(string: "https://api.linear.app/oauth/revoke")!

    /// `read` to mirror teams and projects, `write` to create the issue.
    /// Deliberately NOT `admin`, and deliberately not the `app:assignable` /
    /// `app:mentionable` agent scopes — Yorick is not an agent, and asking
    /// for those would put a workspace-admin approval in front of a personal
    /// integration for capabilities it never uses.
    static let scopes = "read,write"

    /// Linear registers one redirect URI per app, so the loopback port is
    /// FIXED rather than ephemeral — an OS-assigned port would have to be
    /// pre-registered, which is impossible. Chosen from the IANA dynamic
    /// range and unlikely to collide; if it's busy, connecting fails with a
    /// legible error rather than silently binding elsewhere.
    static let redirectPort: UInt16 = 51_484
    static var redirectURI: String { "http://127.0.0.1:\(redirectPort)/oauth/callback" }

    static func authorizationURL(clientID: String, pkce: PKCEChallenge) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// Parse the loopback callback. Returns the code only when `state`
    /// matches the one we generated — an unmatched state is a CSRF attempt
    /// or a stale browser tab, and both deserve the same refusal.
    static func authorizationCode(from path: String, expectedState: String) throws -> String {
        guard let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            throw LinearOAuthError.malformedCallback
        }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw LinearOAuthError.denied(error)
        }
        guard let state = items.first(where: { $0.name == "state" })?.value, state == expectedState else {
            throw LinearOAuthError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw LinearOAuthError.malformedCallback
        }
        return code
    }

    /// Form body for the PKCE token exchange. No `client_secret`: an
    /// open-source app cannot keep one, which is the entire reason this
    /// integration uses PKCE.
    static func tokenRequestBody(clientID: String, code: String, verifier: String) -> String {
        formEncode([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    static func refreshRequestBody(clientID: String, refreshToken: String) -> String {
        formEncode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    static func formEncode(_ fields: [String: String]) -> String {
        // Sorted so the body is deterministic and fixture-testable.
        fields.sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Loopback callback listener

/// A single-shot HTTP listener that exists only to catch the OAuth redirect.
///
/// Loopback (RFC 8252) rather than a custom URL scheme: Linear's redirect-URI
/// validation is documented for `http://localhost` style URIs and unverified
/// for custom schemes, and loopback is the standard native-app pattern
/// regardless. It binds on 127.0.0.1 only, answers exactly one request, and
/// tears itself down — there is no window in which Yorick is a server.
actor LinearCallbackListener {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?

    /// Wait for the browser to hit the redirect URI. Returns the request path
    /// (with its query), or throws on timeout, cancel, or bind failure.
    func waitForCallback(timeout: Duration = .seconds(300)) async throws -> String {
        // stop() on EVERY exit, including the throwing ones: the listener
        // holds a port and a closure that retains this actor, and a flow that
        // times out must not leave either behind.
        do {
            let path = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await self.listen() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw LinearOAuthError.timedOut
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            teardown()
            return path
        } catch {
            teardown()
            throw error
        }
    }

    private func listen() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do {
                let parameters = NWParameters.tcp
                // Loopback only. Without this the listener would accept from
                // the local network, which is a different security posture
                // than "the browser on this machine."
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: .ipv4(.loopback),
                    port: NWEndpoint.Port(rawValue: LinearOAuth.redirectPort)!
                )
                let listener = try NWListener(using: parameters)
                self.listener = listener
                // Bind the weak reference to a `let` before the inner
                // escaping closure captures it — a captured `var self` can't
                // cross into concurrently-executing code.
                listener.newConnectionHandler = { [weak self] connection in
                    let owner = self
                    connection.start(queue: .global(qos: .userInitiated))
                    Self.readRequest(connection) { path in
                        Task { await owner?.finish(with: path) }
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    let owner = self
                    if case .failed(let error) = state {
                        Task { await owner?.fail(with: LinearOAuthError.listenerFailed(error.localizedDescription)) }
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            } catch {
                self.continuation = nil
                continuation.resume(throwing: LinearOAuthError.listenerFailed(error.localizedDescription))
            }
        }
    }

    /// Read just enough to get the request line. The browser sends a plain
    /// GET; we never need headers or a body, so one receive is sufficient.
    private nonisolated static func readRequest(
        _ connection: NWConnection,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
            defer { connection.cancel() }
            if let error {
                completion(.failure(LinearOAuthError.listenerFailed(error.localizedDescription)))
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n").first else {
                completion(.failure(LinearOAuthError.malformedCallback))
                return
            }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else {
                completion(.failure(LinearOAuthError.malformedCallback))
                return
            }
            // Answer before cancelling so the user sees a finished page
            // rather than a connection-reset error in their browser.
            let body = Self.completionPage
            let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r
                \(body)
                """
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                completion(.success(String(parts[1])))
            })
        }
    }

    private func finish(with result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func fail(with error: Error) {
        finish(with: .failure(error))
    }

    func stop() async {
        teardown()
    }

    /// Release the port and settle any waiter. Safe to call twice — the
    /// continuation is cleared before it's resumed.
    private func teardown() {
        listener?.cancel()
        listener = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: LinearOAuthError.cancelled)
        }
    }

    /// Bone on near-black, matching the app — the one moment Yorick renders
    /// anything in a browser, so it shouldn't look like a default error page.
    private static let completionPage = """
        <!doctype html><meta charset="utf-8"><title>Yorick</title>
        <style>
          html{color-scheme:dark}
          body{background:#0d0d0f;color:#ece5d8;font:15px/1.6 -apple-system,BlinkMacSystemFont,sans-serif;
               display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center}
          p{opacity:.6;font-size:13px}
        </style>
        <div><h2>Connected to Linear</h2><p>You can close this tab and go back to Yorick.</p></div>
        """
}

enum LinearOAuthError: Error, LocalizedError, Equatable {
    case notConfigured
    case malformedCallback
    case stateMismatch
    case denied(String)
    case timedOut
    case cancelled
    case listenerFailed(String)
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This build has no Linear client ID, so it can't connect to Linear."
        case .malformedCallback:
            return "Linear sent back a response Yorick couldn't read."
        case .stateMismatch:
            return "The response didn't match this connection attempt. Try connecting again."
        case .denied(let reason):
            return "Linear declined the connection: \(reason)"
        case .timedOut:
            return "The connection timed out. Try again."
        case .cancelled:
            return "Connection cancelled."
        case .listenerFailed(let detail):
            return "Yorick couldn't listen for Linear's response: \(detail)"
        case .tokenExchangeFailed(let detail):
            return "Linear rejected the connection: \(detail)"
        }
    }
}
