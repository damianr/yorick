import Foundation
import AppKit

/// File-based local persistence for captures.
/// Storage layout: ~/Library/Application Support/Yorick/captures/{uuid}/
///   capture.json — metadata
///   screenshot-0.jpg — JPEG screenshot file
///   audio.wav — optional debug WAV when enabled in settings
@MainActor
@Observable
final class CaptureStore {
    var captures: [Capture] = []

    private let capturesDir: URL

    init() {
        capturesDir = AppPaths.root.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)
        captures = loadAll()
    }

    // MARK: - CRUD

    func save(_ capture: Capture, screenshots: [Data], debugAudioURL: URL? = nil) throws {
        let dir = capturesDir.appendingPathComponent(capture.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (i, data) in screenshots.enumerated() {
            try data.write(to: dir.appendingPathComponent("screenshot-\(i).jpg"))
        }

        if let debugAudioURL {
            let destination = dir.appendingPathComponent(AudioDebugSettings.retainedAudioFileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: debugAudioURL, to: destination)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic: a crash mid-write must not leave a truncated capture.json
        // that silently fails to decode (and thus vanishes) on next launch.
        try encoder.encode(capture).write(to: dir.appendingPathComponent("capture.json"), options: .atomic)

        captures.insert(capture, at: 0)
        print("[CaptureStore] Saved capture \(capture.id) (\(capture.mode.rawValue))")
    }

    /// Replace an existing capture's metadata in memory and on disk.
    /// Used to patch in classifier results after the capture was already saved.
    func update(_ capture: Capture) {
        if let index = captures.firstIndex(where: { $0.id == capture.id }) {
            captures[index] = capture
        }
        persistState(capture)
    }

    func delete(_ capture: Capture) {
        let dir = capturesDir.appendingPathComponent(capture.id.uuidString, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            // Capture will resurrect on next launch — at least make it diagnosable.
            print("[CaptureStore] Failed to delete \(capture.id): \(error)")
        }
        captures.removeAll { $0.id == capture.id }
    }

    // MARK: - State Management

    /// Mark a capture as active (user has viewed/expanded it).
    func markActive(_ capture: Capture) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }),
              captures[index].state == .new else { return }
        captures[index].state = .active
        persistState(captures[index])
    }

    /// Mark a capture as done. Stamps `doneAt` so the done-fade prune knows
    /// when the item actually exited.
    func markDone(_ capture: Capture) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        captures[index].state = .done
        captures[index].doneAt = Date()
        persistState(captures[index])
    }

    /// Mark multiple captures as done.
    func markDone(_ ids: Set<UUID>) {
        for id in ids {
            if let index = captures.firstIndex(where: { $0.id == id }) {
                captures[index].state = .done
                captures[index].doneAt = Date()
                persistState(captures[index])
            }
        }
    }

    /// Reopen a done capture (a todo checked off by mistake).
    func markUndone(_ capture: Capture) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        captures[index].state = .active
        captures[index].doneAt = nil
        persistState(captures[index])
    }

    // MARK: - Tag Suggestions

    /// Accept a suggested project tag: it becomes a user-visible applied tag.
    func acceptSuggestedTag(_ capture: Capture, name: String) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        if !captures[index].appliedTags.contains(name) {
            captures[index].appliedTags.append(name)
        }
        captures[index].suggestedTags.removeAll { $0.name == name }
        persistState(captures[index])
    }

    /// Dismiss a suggested project tag.
    func dismissSuggestedTag(_ capture: Capture, name: String) {
        guard let index = captures.firstIndex(where: { $0.id == capture.id }) else { return }
        captures[index].suggestedTags.removeAll { $0.name == name }
        persistState(captures[index])
    }

    private func persistState(_ capture: Capture) {
        let dir = capturesDir.appendingPathComponent(capture.id.uuidString, isDirectory: true)
        let jsonURL = dir.appendingPathComponent("capture.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(capture).write(to: jsonURL, options: .atomic)
        } catch {
            // In-memory state will silently revert on next launch if this fails.
            print("[CaptureStore] Failed to persist \(capture.id): \(error)")
        }
    }

    // MARK: - Session Grouping

    /// Group captures by project tag per day.
    /// All captures tagged "InfuseFlow" on the same calendar day become one session,
    /// even if you switched to other apps in between. Legacy captures (no applied
    /// tags) fall back to `appName` so old records keep their existing grouping.
    func groupedSessions(filter: (Capture) -> Bool = { _ in true }) -> [CaptureSession] {
        let filtered = captures.filter(filter).sorted { $0.timestamp > $1.timestamp }
        guard !filtered.isEmpty else { return [] }

        // Group by (project tag, calendarDay); untagged captures group under
        // the Untagged bucket, never under their host app.
        var groups: [String: [Capture]] = [:]
        for capture in filtered {
            let dayString = Self.dayFormatter.string(from: capture.timestamp)
            let tag = capture.appliedTags.first ?? Self.untaggedBucket
            let key = "\(tag)|\(dayString)"
            groups[key, default: []].append(capture)
        }

        var sessions = groups.map { (_, captures) -> CaptureSession in
            makeSession(from: captures)
        }
        sessions.sort { $0.startTime > $1.startTime }

        return sessions
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func makeSession(from captures: [Capture]) -> CaptureSession {
        let tag = captures.first.map { $0.appliedTags.first ?? Self.untaggedBucket } ?? "Unknown"
        let mostRecent = captures.first?.timestamp ?? Date()
        let dayString = Self.dayFormatter.string(from: mostRecent)
        let id = "\(tag)|\(dayString)"
        return CaptureSession(id: id, appName: tag, captures: captures, startTime: mostRecent)
    }

    // MARK: - Projects

    /// All distinct projects (apps), sorted by most recent activity.
    /// Includes counts of total and new captures per project.
    struct Project: Identifiable, Hashable {
        let appName: String
        let captureCount: Int
        let newCount: Int
        let mostRecent: Date

        var id: String { appName }
    }

    /// The bucket for captures with no real project attribution. Host apps
    /// (Claude, Terminal…) are where you SPOKE, not what it's ABOUT — they
    /// must not masquerade as projects.
    static let untaggedBucket = "Untagged"

    /// One project per unique applied tag. Captures with multiple applied tags
    /// appear under each; captures with none fall into the Untagged bucket,
    /// which is pinned last regardless of recency.
    func projects(filter: (Capture) -> Bool = { $0.state != .done }) -> [Project] {
        let filtered = captures.filter(filter)
        var byTag: [String: [Capture]] = [:]
        for capture in filtered {
            if capture.appliedTags.isEmpty {
                byTag[Self.untaggedBucket, default: []].append(capture)
            } else {
                for tag in capture.appliedTags {
                    byTag[tag, default: []].append(capture)
                }
            }
        }
        var result = byTag.map { (name, caps) in
            Project(
                appName: name,
                captureCount: caps.count,
                newCount: caps.filter { $0.state == .new }.count,
                mostRecent: caps.map(\.timestamp).max() ?? Date.distantPast
            )
        }.sorted { $0.mostRecent > $1.mostRecent }
        if let index = result.firstIndex(where: { $0.appName == Self.untaggedBucket }) {
            let untagged = result.remove(at: index)
            result.append(untagged)
        }
        return result
    }

    /// Project names that have appeared on at least `minCount` captures.
    /// Passed to the classifier so Claude reuses existing tag spellings.
    func candidateProjectNames(minCount: Int = 3, maxCount: Int = 25) -> [String] {
        var counts: [String: Int] = [:]
        for capture in captures {
            for tag in capture.appliedTags {
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .filter { $0.value >= minCount }
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
            .prefix(maxCount)
            .map(\.key)
    }

    // MARK: - Screenshots

    func screenshotURL(for capture: Capture, index: Int) -> URL {
        capturesDir
            .appendingPathComponent(capture.id.uuidString, isDirectory: true)
            .appendingPathComponent("screenshot-\(index).jpg")
    }

    func loadScreenshot(for capture: Capture, index: Int) -> NSImage? {
        NSImage(contentsOf: screenshotURL(for: capture, index: index))
    }

    func audioURL(for capture: Capture) -> URL {
        capturesDir
            .appendingPathComponent(capture.id.uuidString, isDirectory: true)
            .appendingPathComponent(AudioDebugSettings.retainedAudioFileName)
    }

    // MARK: - Maintenance

    func pruneOld(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let old = captures.filter { $0.timestamp < cutoff }
        for capture in old { delete(capture) }
        if !old.isEmpty {
            print("[CaptureStore] Pruned \(old.count) captures older than \(days) days")
        }
    }

    /// Done items exit the stream for good after a grace window. An emptying
    /// stream is the structural guarantee against the archive-graveyard —
    /// artifacts leave, they don't accumulate. Legacy done records without a
    /// `doneAt` stamp fall back to their capture timestamp (they're old anyway).
    func pruneDone(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let old = captures.filter { capture in
            capture.state == .done && (capture.doneAt ?? capture.timestamp) < cutoff
        }
        for capture in old { delete(capture) }
        if !old.isEmpty {
            print("[CaptureStore] Pruned \(old.count) done captures completed over \(days) days ago")
        }
    }

    /// Shorter window for pure dictations — their text already landed in the
    /// target document. A capture the user ever flipped to a note (a `.noted`
    /// effect) is exempt and lives by the normal retention rules.
    func pruneEphemeralDictations(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let old = captures.filter { capture in
            capture.timestamp < cutoff
                && capture.kind == .dictation
                && !capture.effects.contains(where: { $0.kind == .noted })
        }
        for capture in old { delete(capture) }
        if !old.isEmpty {
            print("[CaptureStore] Pruned \(old.count) ephemeral dictations older than \(days) days")
        }
    }

    // MARK: - Private

    private func loadAll() -> [Capture] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: capturesDir, includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [Capture] = []
        for dir in contents where dir.hasDirectoryPath {
            let jsonURL = dir.appendingPathComponent("capture.json")
            guard let data = try? Data(contentsOf: jsonURL) else {
                print("[CaptureStore] Unreadable capture.json in \(dir.lastPathComponent)")
                continue
            }
            do {
                loaded.append(try decoder.decode(Capture.self, from: data))
            } catch {
                // Skipped captures stay on disk but are invisible — make that loud.
                print("[CaptureStore] Failed to decode \(dir.lastPathComponent): \(error)")
            }
        }

        return loaded.sorted { $0.timestamp > $1.timestamp }
    }
}
