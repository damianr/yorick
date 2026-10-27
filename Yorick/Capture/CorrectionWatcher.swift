import AppKit
import ApplicationServices

/// After a dictation is typed, keeps an eye on that one field for a couple
/// of minutes to catch the user fixing a word Yorick got wrong — "weights"
/// retyped as "Waits" — and hands that fix over as a vocabulary suggestion.
///
/// Reads the field's text through Accessibility, on this Mac, and keeps
/// nothing: each read is compared against what Yorick typed and dropped.
/// Never watches a password field. Off with the "Suggest words from my
/// fixes" setting.
@MainActor
final class CorrectionWatcher {
    private static let pollInterval: TimeInterval = 1.5
    private static let watchSeconds: TimeInterval = 120
    /// The paste lands asynchronously, and some AX trees lag behind it; an
    /// unrecognizable field this early is not yet a sign the text is gone.
    private static let landingGrace: TimeInterval = 5
    /// A field bigger than this is a document — not worth aligning per poll.
    private static let maxFieldUTF16 = 200_000

    private var timer: Timer?
    private var element: AXUIElement?
    private var typed = ""
    private var startedAt = Date()
    private var lastValue: String?
    private var pending: [VocabularySuggestion] = []
    private var delivered: Set<VocabularySuggestion> = []
    private var sawTypedText = false

    /// Start watching the focused field, which just received `typed`.
    func watch(typed: String) {
        stop()
        guard VocabularyDefaults.learnsFromFixes,
              AXIsProcessTrusted(),
              CorrectionLearner.words(typed).count <= CorrectionLearner.maxTypedWords,
              let element = AccessibilityCapture.focusedElementIdentity() else { return }
        let subrole = AccessibilityCapture.attribute(element, kAXSubroleAttribute) as? String
        guard subrole != "AXSecureTextField" else { return }

        self.element = element
        self.typed = typed
        startedAt = Date()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stop watching. A fix already seen on the last look still counts.
    /// No final read: this runs at hotkey-down, where an AX round-trip to a
    /// slow app would delay the pill.
    func stop() {
        commit()
        finish()
    }

    private func poll() {
        guard let element else { finish(); return }
        let elapsed = Date().timeIntervalSince(startedAt)
        defer { if timer != nil, elapsed > Self.watchSeconds { stop() } }

        guard let value = Self.text(of: element) else {
            // Field gone or unreadable (window closed, composer rebuilt on
            // send). Whatever was already seen is the last word.
            if sawTypedText || elapsed > Self.landingGrace {
                commit()
                finish()
            }
            return
        }
        if value == lastValue {
            // Held still for a whole poll — the edit is finished.
            commit()
            return
        }
        lastValue = value
        if let found = CorrectionLearner.suggestions(typed: typed, current: value) {
            sawTypedText = true
            pending = found
        } else if sawTypedText || elapsed > Self.landingGrace {
            // Sent, cleared, or rewritten. A fix made just before sending
            // was seen on an earlier poll and still counts.
            commit()
            finish()
        }
    }

    private func commit() {
        for suggestion in pending where !delivered.contains(suggestion) {
            delivered.insert(suggestion)
            // Store access waits for a real suggestion, so watching never
            // touches (and seeds) the vocabulary early.
            guard VocabularyStore.shared.offer(suggestion) else { continue }
            print("[Vocabulary] Suggesting a heard-as rule from a user fix")
            NotificationManager.sendVocabularySuggestion(suggestion)
        }
        pending = []
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        element = nil
        typed = ""
        lastValue = nil
        pending = []
        delivered = []
        sawTypedText = false
    }

    private static func text(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success,
              let value = ref as? String,
              value.utf16.count <= maxFieldUTF16 else { return nil }
        return value
    }
}
