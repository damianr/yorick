import Foundation

struct LinearTeam: Codable, Sendable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    /// The short prefix Linear puts on issue identifiers ("ENG" in ENG-142).
    let key: String
}

struct LinearProject: Codable, Sendable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    /// Linear's project description. This is the single most useful signal
    /// the composer gets — it's how a human would tell these projects apart,
    /// so it's what the model is shown.
    let summary: String?
    let teamIDs: [String]
}

/// The workspace's real teams and projects — the composer's answer key.
///
/// This is what makes on-device routing tractable. The enrichment era asked a
/// weak model to invent a taxonomy with no right answer; here the choice set
/// is small, real, user-owned, and checkable, which is the one shape a small
/// model handles well.
struct LinearWorkspace: Codable, Sendable, Equatable {
    /// Which Linear workspace this mirror belongs to. A Linear OAuth token is
    /// scoped to ONE workspace, so identity has to be visible: without it,
    /// connecting again silently swaps everything out and the only tell is
    /// that your projects changed.
    var organizationID: String?
    var organizationName: String?
    var teams: [LinearTeam]
    var projects: [LinearProject]
    var fetchedAt: Date

    init(
        organizationID: String? = nil,
        organizationName: String? = nil,
        teams: [LinearTeam],
        projects: [LinearProject],
        fetchedAt: Date
    ) {
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.teams = teams
        self.projects = projects
        self.fetchedAt = fetchedAt
    }

    static let empty = LinearWorkspace(teams: [], projects: [], fetchedAt: .distantPast)

    var isEmpty: Bool { teams.isEmpty }

    /// A day is long enough that connecting doesn't re-fetch on every send,
    /// and short enough that a project created this morning is routable this
    /// afternoon. A stale mirror costs one correction, never a failure.
    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 86_400 }

    func projects(forTeam teamID: String) -> [LinearProject] {
        projects.filter { $0.teamIDs.contains(teamID) }
    }

    func team(id: String?) -> LinearTeam? {
        guard let id else { return nil }
        return teams.first { $0.id == id }
    }

    func project(id: String?) -> LinearProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }
}

/// Every connected workspace, and the flat views routing needs across them.
///
/// A Linear OAuth token is scoped to ONE workspace, so "connected to Linear"
/// is really a set of connections. Teams carry their workspace with them
/// because the team is what determines which token creates the issue —
/// picking a team already picks a workspace, which is why routing never has
/// to choose one explicitly.
struct LinearWorkspaces: Codable, Sendable, Equatable {
    var all: [LinearWorkspace] = []

    static let empty = LinearWorkspaces()

    var isEmpty: Bool { all.allSatisfy(\.teams.isEmpty) }
    var isStale: Bool { all.contains { $0.isStale } }
    var organizationIDs: [String] { all.compactMap(\.organizationID) }

    /// A team plus the workspace that owns it — the unit routing works in.
    struct TeamRef: Sendable, Equatable, Identifiable, Hashable {
        let team: LinearTeam
        let workspaceID: String
        let workspaceName: String
        var id: String { team.id }
        /// Disambiguated only when it needs to be: two workspaces routinely
        /// both have an "Engineering", and one workspace never does.
        func label(qualified: Bool) -> String {
            qualified ? "\(workspaceName) › \(team.name)" : team.name
        }
    }

    var teams: [TeamRef] {
        all.flatMap { workspace in
            workspace.teams.map {
                TeamRef(team: $0,
                        workspaceID: workspace.organizationID ?? "",
                        workspaceName: workspace.organizationName ?? "Linear")
            }
        }
    }

    var needsWorkspaceQualifier: Bool { all.count > 1 }

    func workspace(id: String?) -> LinearWorkspace? {
        guard let id else { return nil }
        return all.first { $0.organizationID == id }
    }

    func workspace(forTeam teamID: String) -> LinearWorkspace? {
        all.first { $0.teams.contains { $0.id == teamID } }
    }

    func team(id: String?) -> TeamRef? {
        guard let id else { return nil }
        return teams.first { $0.team.id == id }
    }

    func projects(forTeam teamID: String) -> [LinearProject] {
        workspace(forTeam: teamID)?.projects(forTeam: teamID) ?? []
    }

    func project(id: String?) -> LinearProject? {
        guard let id else { return nil }
        return all.compactMap { $0.project(id: id) }.first
    }

    /// Replace one workspace's mirror, or add it. Keyed on organization id,
    /// so reconnecting the same workspace refreshes rather than duplicates.
    mutating func adopt(_ workspace: LinearWorkspace) {
        guard let id = workspace.organizationID else { return }
        if let index = all.firstIndex(where: { $0.organizationID == id }) {
            all[index] = workspace
        } else {
            all.append(workspace)
        }
    }

    mutating func remove(workspaceID: String) {
        all.removeAll { $0.organizationID == workspaceID }
    }
}

/// Disk cache for the mirror. Plain JSON in Application Support beside the
/// captures: team and project NAMES are workspace metadata, not credentials —
/// the token is the secret, and it lives in the Keychain. Disconnecting
/// deletes this file, because a disconnected app has no business remembering
/// the shape of a workspace it can no longer reach.
enum LinearWorkspaceCache {
    private static var url: URL { AppPaths.root.appendingPathComponent("linear-workspaces.json") }
    /// The single-workspace file this replaced. Read once, then deleted.
    private static var legacyURL: URL { AppPaths.root.appendingPathComponent("linear-workspace.json") }

    static func load() -> LinearWorkspaces {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(LinearWorkspaces.self, from: data) {
            return decoded
        }
        // Migration: one workspace becomes a set of one. Plain metadata, no
        // Keychain involved, so this is safe to run at launch.
        if let data = try? Data(contentsOf: legacyURL),
           let single = try? JSONDecoder().decode(LinearWorkspace.self, from: data) {
            let migrated = LinearWorkspaces(all: [single])
            save(migrated)
            try? FileManager.default.removeItem(at: legacyURL)
            return migrated
        }
        return .empty
    }

    static func save(_ workspaces: LinearWorkspaces) {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: legacyURL)
    }
}
