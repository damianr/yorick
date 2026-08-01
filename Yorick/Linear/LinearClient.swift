import Foundation

/// Minimal GraphQL client for Linear. Deliberately hand-rolled: the official
/// SDK would pull a dependency graph into an app whose whole claim is that
/// you can audit what it does on the network, and this integration needs
/// exactly four operations.
///
/// EVERY request in this file originates from a user pressing a button. There
/// is no polling, no background refresh, no telemetry — the only unattended
/// network call is a token refresh immediately before a request the user just
/// asked for.
actor LinearClient {
    static let endpoint = URL(string: "https://api.linear.app/graphql")!

    private var tokens: LinearKeychain.Tokens?
    /// The token is read on FIRST USE, not at init. This client is
    /// constructed when the app builds its UI, and reading the secret there
    /// is what put a modal keychain dialog in front of a user who had merely
    /// launched the app.
    private var didLoadTokens = false
    private let clientID: String?
    private let session: URLSession
    /// The listener for a connect currently in flight, so the user can give
    /// up on one that will never complete — an authorize page that errors
    /// (wrong workspace, unknown client) never redirects, and without this
    /// the app waits the full timeout with no way out.
    private var activeListener: LinearCallbackListener?

    init(clientID: String? = LinearConfig.clientID, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    /// Reading the secret can raise the system keychain dialog when the
    /// item's ACL doesn't trust this binary, so it happens only here — inside
    /// a request the user explicitly asked for.
    private func currentTokens() -> LinearKeychain.Tokens? {
        if !didLoadTokens {
            tokens = LinearKeychain.load()
            didLoadTokens = true
        }
        return tokens
    }

    var isConnected: Bool { LinearKeychain.hasStoredTokens() }

    // MARK: - Connect / disconnect

    /// The full PKCE dance: open the browser, catch the loopback redirect,
    /// exchange the code. Returns once tokens are in the Keychain.
    func connect(openURL: @Sendable @escaping (URL) -> Void) async throws {
        guard let clientID, !clientID.isEmpty else { throw LinearOAuthError.notConfigured }
        let pkce = PKCEChallenge()
        let listener = LinearCallbackListener()
        activeListener = listener
        defer { activeListener = nil }

        // Bind FIRST, and await it. Opening the browser before the socket is
        // up spends the user's authorization on a redirect nothing can catch:
        // field-reported as ERR_CONNECTION_REFUSED on a valid code. A bind
        // failure now surfaces before the user has approved anything.
        try await listener.start()

        openURL(LinearOAuth.authorizationURL(clientID: clientID, pkce: pkce))

        let path: String
        do {
            path = try await listener.waitForCallback()
        } catch {
            await listener.stop()
            throw error
        }
        let code = try LinearOAuth.authorizationCode(from: path, expectedState: pkce.state)
        let body = LinearOAuth.tokenRequestBody(clientID: clientID, code: code, verifier: pkce.verifier)
        let tokens = try await exchange(body: body, url: LinearOAuth.tokenURL)
        try LinearKeychain.save(tokens)
        self.tokens = tokens
        self.didLoadTokens = true
    }

    /// Abandon a connect in flight. Safe to call when none is running.
    func cancelConnect() async {
        await activeListener?.stop()
    }

    /// Disconnect. Revocation is best-effort — the local token is cleared
    /// either way, because a user who pressed Disconnect must end up
    /// disconnected regardless of whether Linear's endpoint answered.
    func disconnect() async {
        if let token = currentTokens()?.accessToken {
            var request = URLRequest(url: LinearOAuth.revokeURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await session.data(for: request)
        }
        LinearKeychain.clear()
        tokens = nil
        didLoadTokens = true
    }

    private func exchange(body: String, url: URL) async throws -> LinearKeychain.Tokens {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LinearOAuthError.tokenExchangeFailed("HTTP \(status)")
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw LinearOAuthError.tokenExchangeFailed("unreadable token response")
        }
        return LinearKeychain.Tokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: decoded.expires_in.map { Date().addingTimeInterval($0) }
        )
    }

    /// Refresh if the stored token has expired and we have the means to.
    /// Without a refresh token the only honest outcome is to make the user
    /// reconnect, so say that rather than failing the request opaquely.
    private func validAccessToken() async throws -> String {
        guard let current = currentTokens() else { throw LinearClientError.notConnected }
        guard current.isExpired else { return current.accessToken }
        guard let refreshToken = current.refreshToken, let clientID else {
            throw LinearClientError.reconnectRequired
        }
        let body = LinearOAuth.refreshRequestBody(clientID: clientID, refreshToken: refreshToken)
        let refreshed = try await exchange(body: body, url: LinearOAuth.tokenURL)
        // Linear may omit a new refresh token; keep the existing one so the
        // connection doesn't silently become single-use.
        var merged = refreshed
        if merged.refreshToken == nil { merged.refreshToken = refreshToken }
        try LinearKeychain.save(merged)
        tokens = merged
        didLoadTokens = true
        return merged.accessToken
    }

    // MARK: - GraphQL

    private func perform<T: Decodable & Sendable>(
        query: String,
        variables: [String: any Sendable] = [:],
        decoding: T.Type
    ) async throws -> T {
        let token = try await validAccessToken()
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        var payload: [String: any Sendable] = ["query": query]
        if !variables.isEmpty { payload["variables"] = variables }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LinearClientError.transport("no response") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw LinearClientError.reconnectRequired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LinearClientError.transport("HTTP \(http.statusCode)")
        }
        let envelope = try JSONDecoder().decode(GraphQLEnvelope<T>.self, from: data)
        if let message = envelope.errors?.first?.message {
            throw LinearClientError.api(message)
        }
        guard let payload = envelope.data else { throw LinearClientError.api("empty response") }
        return payload
    }

    // MARK: - Operations

    /// The answer key for the composer: the teams and projects that actually
    /// exist in this workspace. Archived projects are excluded — routing a
    /// new capture into a finished project is never right.
    func fetchWorkspace() async throws -> LinearWorkspace {
        struct Response: Decodable, Sendable {
            struct Teams: Decodable, Sendable { let nodes: [LinearTeam] }
            struct Projects: Decodable, Sendable { let nodes: [ProjectNode] }
            struct ProjectNode: Decodable, Sendable {
                struct TeamRefs: Decodable, Sendable { let nodes: [IDOnly] }
                struct IDOnly: Decodable, Sendable { let id: String }
                let id: String
                let name: String
                let description: String?
                let state: String?
                let teams: TeamRefs
            }
            struct Organization: Decodable, Sendable {
                let id: String
                let name: String
            }
            let organization: Organization?
            let teams: Teams
            let projects: Projects
        }
        // No server-side state filter. A filter argument this client can't
        // test against a live schema is a way for the whole connect flow to
        // look broken over a cosmetic preference — so the query stays plain
        // and the exclusion happens below, where a schema change costs
        // nothing worse than an extra project in the menu.
        let query = """
            query YorickWorkspace {
              organization { id name }
              teams(first: 100) { nodes { id name key } }
              projects(first: 100) {
                nodes { id name description state teams(first: 10) { nodes { id } } }
              }
            }
            """
        let response = try await perform(query: query, decoding: Response.self)
        // Routing a new capture into a finished project is never right.
        let closed: Set<String> = ["completed", "canceled", "cancelled"]
        let projects = response.projects.nodes
            .filter { !closed.contains(($0.state ?? "").lowercased()) }
            .map { node in
                LinearProject(
                    id: node.id,
                    name: node.name,
                    summary: node.description,
                    teamIDs: node.teams.nodes.map(\.id)
                )
            }
        return LinearWorkspace(
            organizationID: response.organization?.id,
            organizationName: response.organization?.name,
            teams: response.teams.nodes,
            projects: projects,
            fetchedAt: Date()
        )
    }

    /// Create the issue. Returns what the card needs to show that it landed.
    func createIssue(_ draft: LinearIssueDraft) async throws -> LinearCreatedIssue {
        struct Response: Decodable, Sendable {
            struct Payload: Decodable, Sendable {
                let success: Bool
                let issue: LinearCreatedIssue?
            }
            let issueCreate: Payload
        }
        var input: [String: any Sendable] = [
            "teamId": draft.teamID,
            "title": draft.title,
            "description": draft.description,
        ]
        if let projectID = draft.projectID { input["projectId"] = projectID }

        let mutation = """
            mutation YorickCreateIssue($input: IssueCreateInput!) {
              issueCreate(input: $input) {
                success
                issue { id identifier url title }
              }
            }
            """
        let response = try await perform(query: mutation, variables: ["input": input], decoding: Response.self)
        guard response.issueCreate.success, let issue = response.issueCreate.issue else {
            throw LinearClientError.api("Linear declined to create the issue")
        }
        return issue
    }
}

/// GraphQL reports failures inside a 200, so the errors array — not the
/// status code — is the real status check.
private struct GraphQLEnvelope<Payload: Decodable>: Decodable {
    struct GraphQLError: Decodable { let message: String }
    let data: Payload?
    let errors: [GraphQLError]?
}

/// Where the client ID comes from. Info.plist for shipping builds (injected
/// at build time), with a `defaults` override so the integration can be
/// exercised against a personal OAuth app without a rebuild:
///   defaults write com.heyyorick.Yorick linearClientID -string "<id>"
enum LinearConfig {
    static var clientID: String? {
        if let override = UserDefaults.standard.string(forKey: "linearClientID"), !override.isEmpty {
            return override
        }
        let bundled = Bundle.main.object(forInfoDictionaryKey: "LinearClientID") as? String
        // The Info.plist ships the unsubstituted placeholder when no client
        // ID was configured for the build; treat that as absent.
        guard let bundled, !bundled.isEmpty, !bundled.hasPrefix("$(") else { return nil }
        return bundled
    }

    static var isConfigured: Bool { clientID != nil }
}

enum LinearClientError: Error, LocalizedError, Equatable {
    case notConnected
    case reconnectRequired
    case transport(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Yorick isn't connected to Linear yet."
        case .reconnectRequired:
            return "Your Linear connection expired. Reconnect in Settings."
        case .transport(let detail):
            return "Couldn't reach Linear: \(detail)"
        case .api(let message):
            return message
        }
    }
}
