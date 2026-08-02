import Foundation

/// User-facing state for the Linear integration. Off by default, and off is
/// the whole default path — installing Yorick still requires no account, no
/// key, and no configuration.
///
/// `collectsContext` is the important one. Screen context is gathered ONLY
/// when this integration is on, so a user who never connects Linear has an
/// app that reads nothing beyond "is a field focused" — the same app it was
/// before this feature existed. That keeps the privacy story a single
/// sentence for everyone who doesn't opt in, and makes the opt-in honest for
/// everyone who does.
@MainActor
final class LinearSettings: ObservableObject {
    static let shared = LinearSettings()

    private enum Keys {
        static let enabled = "linearIntegrationEnabled"
        static let defaultTeamID = "linearDefaultTeamID"
        static let composeWithModel = "linearComposeWithModel"
    }

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    /// Where captures go when the composer has no better idea. Set at connect
    /// time from the first team, changeable in Settings.
    @Published var defaultTeamID: String? {
        didSet { UserDefaults.standard.set(defaultTeamID, forKey: Keys.defaultTeamID) }
    }

    /// Whether the on-device model proposes a title and a route. Off means
    /// every send uses the deterministic draft — which is exactly what a
    /// model failure produces anyway, so this toggle is a preference, not a
    /// safety valve.
    @Published var composeWithModel: Bool {
        didSet { UserDefaults.standard.set(composeWithModel, forKey: Keys.composeWithModel) }
    }

    @Published var workspaces: LinearWorkspaces
    @Published var isConnected: Bool

    private init() {
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
        self.defaultTeamID = defaults.string(forKey: Keys.defaultTeamID)
        self.composeWithModel = defaults.object(forKey: Keys.composeWithModel) as? Bool ?? true
        self.workspaces = LinearWorkspaceCache.load()
        // Existence, not the secret. This initializer runs on the path that
        // the dictation hotkey touches (`collectsContext`), and reading the
        // token here is what let a modal keychain dialog appear at launch.
        self.isConnected = LinearKeychain.hasStoredTokens()
    }

    /// The gate for screen-context collection. Both conditions matter: a
    /// connected-but-disabled integration collects nothing, and so does an
    /// enabled-but-disconnected one.
    var collectsContext: Bool { isEnabled && isConnected }

    /// True when a capture can actually be sent right now.
    var canSend: Bool { collectsContext && !workspaces.teams.isEmpty }

    func adopt(workspace: LinearWorkspace) {
        workspaces.adopt(workspace)
        LinearWorkspaceCache.save(workspaces)
        // The first connection picks a default so the first send needs no
        // setup; later ones leave an existing default alone, because adding a
        // second workspace should never silently redirect the first.
        if defaultTeamID == nil || workspaces.team(id: defaultTeamID) == nil {
            defaultTeamID = workspaces.teams.first?.id
        }
    }

    /// Forget one connection. The default team follows if it lived there.
    func remove(workspaceID: String) {
        workspaces.remove(workspaceID: workspaceID)
        LinearWorkspaceCache.save(workspaces)
        if workspaces.team(id: defaultTeamID) == nil {
            defaultTeamID = workspaces.teams.first?.id
        }
        if workspaces.teams.isEmpty { isConnected = false }
    }

    func markConnected() {
        isConnected = true
        isEnabled = true
    }

    func markDisconnected() {
        isConnected = false
        workspaces = .empty
        defaultTeamID = nil
        LinearWorkspaceCache.clear()
    }
}
