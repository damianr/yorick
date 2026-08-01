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

    @Published var workspace: LinearWorkspace
    @Published var isConnected: Bool

    private init() {
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
        self.defaultTeamID = defaults.string(forKey: Keys.defaultTeamID)
        self.composeWithModel = defaults.object(forKey: Keys.composeWithModel) as? Bool ?? true
        self.workspace = LinearWorkspaceCache.load() ?? .empty
        self.isConnected = LinearKeychain.load() != nil
    }

    /// The gate for screen-context collection. Both conditions matter: a
    /// connected-but-disabled integration collects nothing, and so does an
    /// enabled-but-disconnected one.
    var collectsContext: Bool { isEnabled && isConnected }

    /// True when a capture can actually be sent right now.
    var canSend: Bool { collectsContext && !workspace.teams.isEmpty }

    func adopt(workspace: LinearWorkspace) {
        self.workspace = workspace
        LinearWorkspaceCache.save(workspace)
        // First connection picks a default so the first send needs no setup.
        if defaultTeamID == nil || workspace.team(id: defaultTeamID) == nil {
            defaultTeamID = workspace.teams.first?.id
        }
    }

    func markConnected() {
        isConnected = true
        isEnabled = true
    }

    func markDisconnected() {
        isConnected = false
        workspace = .empty
        defaultTeamID = nil
        LinearWorkspaceCache.clear()
    }
}
