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
    var teams: [LinearTeam]
    var projects: [LinearProject]
    var fetchedAt: Date

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

/// Disk cache for the mirror. Plain JSON in Application Support beside the
/// captures: team and project NAMES are workspace metadata, not credentials —
/// the token is the secret, and it lives in the Keychain. Disconnecting
/// deletes this file, because a disconnected app has no business remembering
/// the shape of a workspace it can no longer reach.
enum LinearWorkspaceCache {
    private static var url: URL { AppPaths.root.appendingPathComponent("linear-workspace.json") }

    static func load() -> LinearWorkspace? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LinearWorkspace.self, from: data)
    }

    static func save(_ workspace: LinearWorkspace) {
        guard let data = try? JSONEncoder().encode(workspace) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
