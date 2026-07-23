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
        focusedEditableAtStop: Bool
    ) -> Decision {
        if let prefix = leadingNotePrefix(in: transcript) {
            return Decision(disposition: .note, reason: "register: starts with \"\(prefix)\"")
        }

        // Detection routes intent, it does not veto typing. Dictation intent at
        // start (the cursor was in a field), or a live editor at stop, both read
        // as dictation; whether a paste actually lands is decided downstream by
        // whether anything is focused. Only a contextual start with no editor at
        // stop files into the stream.
        if modeAtStart == .dictation || focusedEditableAtStop {
            return Decision(
                disposition: .insert,
                reason: focusedEditableAtStop ? "editor focused at stop" : "dictation intent at start"
            )
        }
        return Decision(disposition: .note, reason: "no dictation intent, no editor focused")
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
