import CryptoKit
import Darwin
import Foundation

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

    /// `prompt=consent` is sent ALWAYS, not just on a switch.
    ///
    /// A token is scoped to one workspace, and without this Linear can hand
    /// back a code for the already-authorized workspace without showing the
    /// picker — so "Switch workspace" reconnects you to the workspace you
    /// were trying to leave and looks like it did nothing. Field-reported.
    /// Forcing the consent screen costs a first-time user nothing, since
    /// they see it anyway.
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
            URLQueryItem(name: "prompt", value: "consent"),
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

/// A boolean shared between the actor and its off-actor accept loop.
/// A lock rather than an atomic because it is read a handful of times per
/// second, and correctness here is worth more than the nanoseconds.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

// MARK: - Loopback callback listener

/// A single-shot HTTP listener that exists only to catch the OAuth redirect.
///
/// Loopback (RFC 8252) rather than a custom URL scheme: Linear accepts a
/// `http://127.0.0.1:<port>` redirect (verified against a real OAuth app,
/// 2026-08-01), and loopback is the standard native-app pattern regardless.
/// It binds 127.0.0.1 only, answers exactly one request, and tears itself
/// down — there is no window in which Yorick is a server.
///
/// A PLAIN BSD SOCKET, not `NWListener`. The first version used Network
/// framework and failed in the field with ERR_CONNECTION_REFUSED on a valid
/// authorization code. Probed afterwards: every `NWListener` binding form —
/// `on: port`, `requiredLocalEndpoint`, both, neither — returns POSIX EINVAL
/// (22) here, while `bind`/`listen` on the same port succeeds immediately.
/// The cause was not worth chasing further, because the conclusion held
/// either way: Network framework routes through a system daemon and carries
/// failure modes this job has no use for. Listening on loopback for one HTTP
/// GET is forty lines of POSIX that work everywhere, including under the
/// test harness — which is what lets the regression test actually guard it.
actor LinearCallbackListener {
    private var listenFD: Int32 = -1
    /// Read by the accept loop, which runs off-actor. Set by `stop()` so a
    /// cancelled connect ends as a cancellation rather than as whatever
    /// errno a closed descriptor happens to produce.
    private let cancelled = CancelFlag()

    /// Bind the port. Separate from `waitForCallback` and awaited BEFORE the
    /// browser opens, because the two must not race: the original version
    /// started listening with `async let` and opened the browser in the same
    /// breath, so a bind failure surfaced only after the user had already
    /// approved the app — the code spent, and nothing there to catch it.
    func start() throws {
        guard listenFD < 0 else { throw LinearOAuthError.listenerFailed("already listening") }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LinearOAuthError.listenerFailed(Self.errnoText()) }

        // A socket left in TIME_WAIT by a previous attempt must not block the
        // retry; the user trying again is the common case after a failure.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = LinearOAuth.redirectPort.bigEndian
        // INADDR_LOOPBACK, so the socket is unreachable from the network.
        // This is the security property, and here it comes from the bind
        // itself rather than from a parameter the framework might ignore.
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let message = Self.errnoText()
            close(fd)
            throw LinearOAuthError.listenerFailed("port \(LinearOAuth.redirectPort): \(message)")
        }
        guard listen(fd, 1) == 0 else {
            let message = Self.errnoText()
            close(fd)
            throw LinearOAuthError.listenerFailed(message)
        }
        listenFD = fd
    }

    /// Wait for the browser to hit the redirect URI. Returns the request path
    /// with its query, or throws on timeout, cancel, or teardown.
    func waitForCallback(timeout: Duration = .seconds(300)) async throws -> String {
        guard listenFD >= 0 else { throw LinearOAuthError.listenerFailed("not started") }
        let fd = listenFD
        // Teardown on EVERY exit, including the throwing ones: the socket
        // holds a port, and a flow that times out must not leave it bound.
        do {
            let deadline = ContinuousClock.now + timeout
            let flag = cancelled
            let path = try await Task.detached(priority: .userInitiated) {
                try Self.accept(on: fd, until: deadline, cancelled: flag)
            }.value
            teardown()
            return path
        } catch {
            teardown()
            throw error
        }
    }

    func stop() {
        teardown()
    }

    private func teardown() {
        cancelled.set()
        guard listenFD >= 0 else { return }
        close(listenFD)
        listenFD = -1
    }

    // MARK: - The blocking half

    /// Poll rather than a bare blocking `accept`, so the wait is bounded and
    /// a cancelled task actually stops waiting. One request, then done.
    private nonisolated static func accept(
        on fd: Int32,
        until deadline: ContinuousClock.Instant,
        cancelled: CancelFlag
    ) throws -> String {
        while true {
            // `Task.isCancelled` is not enough: this runs detached, which
            // does not inherit cancellation. The flag is what actually stops
            // it when the user gives up on a connect.
            if cancelled.isSet || Task.isCancelled { throw LinearOAuthError.cancelled }
            if ContinuousClock.now >= deadline { throw LinearOAuthError.timedOut }

            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                throw LinearOAuthError.listenerFailed(errnoText())
            }
            guard ready > 0 else { continue }

            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                throw LinearOAuthError.listenerFailed(errnoText())
            }
            defer { close(client) }

            guard let requestLine = readRequestLine(client) else {
                // A probe that isn't a GET (some browsers speculatively open
                // connections) must not end the wait — keep listening.
                continue
            }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else { continue }

            // Answer before closing, so the user lands on a finished page
            // rather than a connection reset in their browser.
            send(client, completionPage)
            return String(parts[1])
        }
    }

    /// Read up to the end of the request line. The browser sends a plain GET;
    /// headers and body are never needed, so one bounded read is enough.
    private nonisolated static func readRequestLine(_ fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var filled = 0
        while filled < buffer.count {
            let n = buffer[filled...].withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, raw.count)
            }
            guard n > 0 else { break }
            filled += n
            if let newline = buffer[..<filled].firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[..<newline]
                let trimmed = line.last == UInt8(ascii: "\r") ? line.dropLast() : line[...]
                return String(decoding: trimmed, as: UTF8.self)
            }
        }
        return nil
    }

    private nonisolated static func send(_ fd: Int32, _ body: String) {
        let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        var bytes = Array(response.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeMutableBytes { raw in
                write(fd, raw.baseAddress, raw.count)
            }
            guard written > 0 else { break }
            offset += written
        }
    }

    private nonisolated static func errnoText() -> String {
        String(cString: strerror(errno))
    }

    /// Bone on near-black, matching the app — the one moment Yorick renders
    /// anything in a browser, so it shouldn't look like a default error page.
    private nonisolated static let completionPage = """
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
