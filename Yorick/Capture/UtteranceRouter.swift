import Foundation

/// Decides what to DO with an utterance after transcription.
///
/// The cursor/focus evidence gathered at trigger time is a prior, not a verdict:
/// when that evidence was ambiguous, the words themselves (and where keyboard
/// focus is once we're ready to act) pick the disposition. High-confidence and
/// forced starts are never overridden — the router only owns the grey zone.
enum UtteranceRouter {
    enum Disposition: String, Sendable {
        case insert  // type at the cursor (dictation)
        case note    // file in the stream (observation)
    }

    struct Decision: Sendable {
        let disposition: Disposition
        let reason: String
    }

    /// Leading words that mark an utterance as a note regardless of focus.
    /// Matched only at the very start of the transcript — "note that…" mid-email
    /// must not hijack a dictation.
    private static let notePrefixes: [String] = [
        "note to self", "note", "bug", "idea", "reminder", "remind me",
        "todo", "to-do", "to do", "observation", "journal", "thought",
        "remember to", "jot down", "question"
    ]

    @MainActor
    static func route(
        transcript: String,
        modeAtStart: CaptureMode,
        focusedEditableAtStop: Bool,
        appName: String
    ) -> Decision {
        if let prefix = leadingNotePrefix(in: transcript) {
            return Decision(disposition: .note, reason: "register: starts with \"\(prefix)\"")
        }

        // Learned bias: repeated flips in this app outvote the generic default.
        let bias = RoutingCorrections.netInsertBias(for: appName)
        if bias <= -2 {
            return Decision(disposition: .note, reason: "learned: corrected to note \(-bias)× in \(appName)")
        }
        if bias >= 2, focusedEditableAtStop {
            return Decision(disposition: .insert, reason: "learned: corrected to insert \(bias)× in \(appName)")
        }

        // Prose with a live editor under focus reads as dictation; everything
        // else files safely into the stream (insert is the intrusive mistake).
        if focusedEditableAtStop {
            return Decision(disposition: .insert, reason: "prose register + editor focused at stop")
        }
        return Decision(
            disposition: .note,
            reason: modeAtStart == .dictation ? "no editor focused at stop" : "kept contextual default"
        )
    }

    static func leadingNotePrefix(in transcript: String) -> String? {
        let head = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Sorted longest-first so "note to self" wins over "note".
        for prefix in notePrefixes.sorted(by: { $0.count > $1.count }) {
            guard head.hasPrefix(prefix) else { continue }
            // Word boundary after the prefix: "notebook settings" is not a note.
            let after = head.dropFirst(prefix.count)
            if let first = after.first, first.isLetter || first.isNumber { continue }
            return prefix
        }
        return nil
    }
}

/// Persistent record of the user flipping a disposition with the redirect key.
/// Each flip is a labeled example of the router being wrong — used as an
/// app-level bias locally and as few-shot examples for the classifier.
@MainActor
enum RoutingCorrections {
    struct Correction: Codable, Sendable {
        let timestamp: Date
        let appName: String
        /// First few words — enough to learn openings, small enough to not
        /// be a transcript archive.
        let transcriptHead: String
        let from: String  // CaptureEffect.Kind raw value
        let to: String
    }

    private static let maxStored = 100

    private static var fileURL: URL {
        AppPaths.root.appendingPathComponent("routing-corrections.json")
    }

    private static var cache: [Correction]?

    static func record(appName: String, transcript: String, from: CaptureEffect.Kind, to: CaptureEffect.Kind) {
        let head = transcript.split(separator: " ").prefix(12).joined(separator: " ")
        var all = load()
        all.append(Correction(
            timestamp: Date(),
            appName: appName,
            transcriptHead: String(head),
            from: from.rawValue,
            to: to.rawValue
        ))
        if all.count > maxStored {
            all.removeFirst(all.count - maxStored)
        }
        cache = all
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(all).write(to: fileURL, options: .atomic)
        } catch {
            print("[RoutingCorrections] Failed to persist: \(error)")
        }
        print("[RoutingCorrections] Recorded \(from.rawValue)→\(to.rawValue) in \(appName) (\(all.count) total)")
    }

    /// Positive = user keeps flipping toward insert in this app, negative =
    /// toward note. Only counts genuine direction flips.
    static func netInsertBias(for appName: String) -> Int {
        load().filter { $0.appName == appName }.reduce(0) { bias, c in
            if c.to == CaptureEffect.Kind.inserted.rawValue { return bias + 1 }
            if c.to == CaptureEffect.Kind.noted.rawValue { return bias - 1 }
            return bias
        }
    }

    /// Most recent corrections for the classifier prompt.
    static func recent(limit: Int) -> [Correction] {
        Array(load().suffix(limit))
    }

    private static func load() -> [Correction] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: fileURL)).flatMap {
            try? decoder.decode([Correction].self, from: $0)
        } ?? []
        cache = loaded
        return loaded
    }
}
