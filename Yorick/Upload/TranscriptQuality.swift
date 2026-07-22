import Foundation

/// Engine-agnostic guard against two failure modes that make dictation feel broken:
///
/// 1. **Silence** — the mic captured nothing usable (muted, wrong device, dead
///    input). Detected from `AudioDiagnostics` levels before we even transcribe.
/// 2. **Hallucination** — Whisper was trained on a huge pile of YouTube captions,
///    so when fed silence/noise it confidently emits high-frequency caption
///    artifacts ("Thanks for watching", "I hope you enjoyed this video", "Please
///    subscribe") and often loops them. This is deterministic garbage, not real
///    speech, and we never want to insert or save it.
///
/// The whole point is to *fail visibly and harmlessly* (show a notice, insert
/// nothing) instead of confidently pasting nonsense over what the user was doing.
enum TranscriptQuality {

    // MARK: - Verdict

    enum Rejection: Equatable {
        /// No measurable audio reached the app at all.
        case noAudio
        /// Audio was present but contained no detectable speech.
        case noSpeech
        /// Transcript matches a known Whisper hallucination pattern.
        case hallucination
        /// Transcript was empty after cleanup.
        case empty

        /// Short, friendly message shown on the HUD pill.
        var userMessage: String {
            switch self {
            case .noAudio: return "No audio detected — check your microphone"
            case .noSpeech: return "Didn't catch any speech — try again"
            case .hallucination: return "Didn't catch that clearly — try again"
            case .empty: return "Didn't catch that — try again"
            }
        }

        /// Detail string for logging/diagnostics.
        var logReason: String {
            switch self {
            case .noAudio: return "no measurable audio reached the app"
            case .noSpeech: return "audio present but no speech detected"
            case .hallucination: return "transcript matches a Whisper hallucination pattern"
            case .empty: return "empty transcript"
            }
        }
    }

    // MARK: - Tunables

    private enum Threshold {
        /// Below this peak the recording is effectively silent (a real voice,
        /// even quiet/distant, peaks well above this).
        static let silentPeakDBFS = -55.0
        /// Almost no frames cleared the analyzer's active-speech threshold.
        static let minActiveFramePercent = 1.5
        /// And nearly the whole file sat near the noise floor.
        static let dominantNearSilentPercent = 92.0
        /// Share of words belonging to known caption artifacts that flags the
        /// whole transcript as a hallucination.
        static let signatureWordShare = 0.6
        /// Unique-word ratio below which a transcript is pathologically repetitive.
        static let repetitiveUniqueRatio = 0.35
    }

    // MARK: - Stage 1: pre-transcription silence gate

    /// Decide, from audio levels alone, whether it's even worth transcribing.
    /// Conservative on purpose: only fires on near-total silence so genuinely
    /// quiet speech is never dropped here (the text gate is the safety net for
    /// the in-between cases).
    static func silenceRejection(_ diagnostics: AudioDiagnostics?) -> Rejection? {
        guard let diagnostics else { return nil }

        // Peak is nil when no measurable audio reached the app.
        guard let peak = diagnostics.peakDBFS, peak.isFinite else {
            return .noAudio
        }

        if peak < Threshold.silentPeakDBFS {
            return .noSpeech
        }

        if diagnostics.activeFramePercent < Threshold.minActiveFramePercent,
           diagnostics.nearSilentFramePercent > Threshold.dominantNearSilentPercent {
            return .noSpeech
        }

        return nil
    }

    // MARK: - Stage 2: post-transcription content gate

    /// Decide whether a produced transcript is real speech or a hallucination.
    /// `diagnostics` (when available) lets ambiguous single-word results ("you",
    /// "thank you") be rejected only when the audio was also weak — so real terse
    /// dictation survives.
    static func contentRejection(transcript: String, diagnostics: AudioDiagnostics?) -> Rejection? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let normalized = normalize(trimmed)
        guard !normalized.isEmpty else { return .empty }

        let words = normalized.split(separator: " ").map(String.init)
        let weakAudio = diagnostics?.indicatesWeakSpeech ?? false

        // Lone filler tokens Whisper emits on silence. These *can* be real, so
        // only reject when the audio also looks weak.
        if words.count <= 2, ambiguousFillers.contains(normalized), weakAudio {
            return .hallucination
        }

        // Caption-artifact signature phrases. Multi-word YouTube boilerplate that
        // nobody dictates into a productivity tool — reject regardless of audio.
        if signatureWordShare(in: normalized) >= Threshold.signatureWordShare {
            return .hallucination
        }

        // Pathological repetition (Whisper looping the same phrase).
        if isRepetitive(words: words) || hasRepeatedSentence(trimmed) {
            return .hallucination
        }

        return nil
    }

    // MARK: - Hallucination patterns

    /// Lowercased, punctuation-free signatures of Whisper's caption-training bleed.
    private static let signaturePhrases: [String] = [
        "thanks for watching",
        "thank you for watching",
        "thanks for watching this video",
        "thanks for watching and ill see you in the next one",
        "i hope you enjoyed this video",
        "i hope you enjoyed the video",
        "i hope you enjoyed it",
        "if you enjoyed this video",
        "please subscribe",
        "please like and subscribe",
        "like and subscribe",
        "dont forget to subscribe",
        "make sure to subscribe",
        "subscribe to my channel",
        "see you in the next video",
        "see you in the next one",
        "see you next time",
        "thanks for listening",
        "thank you for listening",
        "subtitles by the amaraorg community",
        "subtitles by",
        "transcription by",
        "transcribed by",
        "captions by",
        "music playing",
    ]

    /// Single/short tokens that show up as hallucinations on silence but can also
    /// be legitimate terse speech.
    private static let ambiguousFillers: Set<String> = [
        "you", "thank you", "thanks", "bye", "bye bye", "so", "okay", "uh", "um",
    ]

    /// Fraction of the transcript's words that belong to known signature phrases.
    private static func signatureWordShare(in normalized: String) -> Double {
        let totalWords = normalized.split(separator: " ").count
        guard totalWords > 0 else { return 0 }

        var working = " \(normalized) "
        var matchedWords = 0
        for phrase in signaturePhrases {
            let needle = " \(phrase) "
            while let range = working.range(of: needle) {
                matchedWords += phrase.split(separator: " ").count
                working.replaceSubrange(range, with: " ")
            }
        }

        return min(1.0, Double(matchedWords) / Double(totalWords))
    }

    private static func isRepetitive(words: [String]) -> Bool {
        guard words.count >= 8 else { return false }
        let unique = Set(words).count
        return Double(unique) / Double(words.count) < Threshold.repetitiveUniqueRatio
    }

    /// Detects Whisper looping a whole sentence verbatim (e.g. "I hope you enjoyed
    /// this video. I hope you enjoyed this video.").
    private static func hasRepeatedSentence(_ transcript: String) -> Bool {
        let sentences = transcript
            .split(whereSeparator: { ".!?".contains($0) })
            .map { normalize(String($0)) }
            .filter { $0.split(separator: " ").count >= 4 }

        guard sentences.count >= 2 else { return false }

        var counts: [String: Int] = [:]
        for sentence in sentences {
            counts[sentence, default: 0] += 1
        }

        guard let (_, maxCount) = counts.max(by: { $0.value < $1.value }), maxCount >= 2 else {
            return false
        }

        // The repeated sentence must dominate — guards against a legitimately
        // repeated short clause inside a longer, varied dictation.
        return Double(maxCount) / Double(sentences.count) >= 0.5
    }

    /// Lowercase, strip punctuation/symbols to spaces, collapse whitespace.
    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " {
                return Character(scalar)
            }
            return " "
        }
        return String(mapped)
            .split(separator: " ")
            .joined(separator: " ")
    }
}

// MARK: - Audio level interpretation

extension AudioDiagnostics {
    /// True when the recording's levels suggest weak or marginal speech — used to
    /// tip ambiguous single-word transcripts toward rejection.
    var indicatesWeakSpeech: Bool {
        if let peak = peakDBFS, peak.isFinite, peak < -40 { return true }
        if let snr = signalToNoiseDB, snr.isFinite, snr < 12 { return true }
        if activeFramePercent < 8 { return true }
        if let active = activeSpeechRMSDBFS, active.isFinite, active < -34 { return true }
        return false
    }
}
