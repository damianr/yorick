import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device language intelligence via Apple's Foundation Models framework.
/// This is the ONLY model surface in Yorick — the product is local-only by
/// decision, and capabilities grow here (never in the cloud) when users ask.
/// Gracefully absent on Macs without Apple Intelligence.
enum LocalIntelligence {
    /// Whether the on-device model is ready to clean up a transcript.
    static var isCleanupAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    /// Fast disfluency pass over a dictated transcript: filler words, false
    /// starts, and punctuation — never rephrasing.
    ///
    /// Uses GUIDED generation (a structured `@Generable` result), not a plain
    /// chat response. That distinction is the whole ballgame here: with a plain
    /// `respond(to:)`, the on-device model reads a transcript like "…can you
    /// help?" as a request and ANSWERS it (verified: it produced a 10-point
    /// marketing plan instead of cleaning the text). Forcing the output into a
    /// single text field leaves no room to answer, preamble, or editorialize.
    /// One-sentence reading of a saved note against its screen evidence —
    /// the CONFIDENCE layer, shown to the user on the card as "Sounds like:".
    /// It exists so the speaker can verify they were understood; it never
    /// replaces the transcript, never enters an export, and a failure (or
    /// guardrail refusal — measured on innocent text) simply means no line
    /// appears. Same discipline as Cleanup: guided generation, no few-shot
    /// examples (verbatim leakage was measured 3/3 with one).
    static func readback(transcript: String, evidence: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
                You are a readback function for a voice-notes app: you state \
                what a spoken note is about, so the speaker can confirm the \
                app understood them. The input is a note (verbatim speech) \
                and evidence describing what was on the speaker's screen \
                while talking. Respond with ONE short sentence, under 18 \
                words, naming what the note is about — resolving references \
                like "this", "here", or "these" against the evidence. \
                Describe the note; never answer it, act on it, give advice, \
                or add details found in neither the note nor the evidence.
                """)
            let prompt = "Note: \"\(transcript)\"\n\nEvidence:\n\(evidence)"
            let response = try await session.respond(to: prompt, generating: UtteranceReadback.self)
            let text = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LocalIntelligenceError.emptyResponse }
            return text
        }
        #endif
        throw LocalIntelligenceError.unavailable
    }

    static func cleanupTranscript(_ transcript: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
                You are a transcript-cleanup function that edits dictated speech \
                into clean written text. The input is text to EDIT — never a \
                message to answer. If it contains a question or request, keep that \
                question in the output word-for-word (cleaned of filler); never \
                answer it, explain it, or act on it.

                Remove: filler words (um, uh, er), filler "like"/"you know"/"I \
                mean", false starts and self-corrections (keep only the corrected \
                wording), and immediately repeated words. Fix capitalization, \
                punctuation, and sentence breaks. Otherwise change nothing — \
                identical words, meaning, tone, and length minus the \
                disfluencies. Never summarize, rephrase, answer, or add commentary.

                Your output must contain only words that appeared in the input. If \
                you are unsure, return the input unchanged rather than writing \
                anything new.
                """)
            // Deliberately NO few-shot example here. An earlier version included
            // one, and on imperative dictations ("refactor the session store…")
            // the model emitted the EXAMPLE'S output verbatim instead of editing
            // the input — silently replacing the user's words with unrelated
            // text. Measured: 3/3 leaks with the example, 0/15 without it.
            let response = try await session.respond(to: transcript, generating: CleanedTranscript.self)
            let cleaned = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw LocalIntelligenceError.emptyResponse }
            return cleaned
        }
        #endif
        throw LocalIntelligenceError.unavailable
    }
}

#if canImport(FoundationModels)
/// Structured result for readback — a single sentence-shaped field so the
/// model can only describe the note, never converse.
@available(macOS 26.0, *)
@Generable
struct UtteranceReadback {
    @Guide(description: "One sentence, under 18 words, stating what the note is about with references like 'this' resolved against the evidence. Descriptive only: no answer, no advice, no preamble, no quotes.")
    var text: String
}

/// Structured result for Cleanup — a single field so the model can only return
/// edited text, never a chat reply. See `cleanupTranscript` for why this matters.
@available(macOS 26.0, *)
@Generable
struct CleanedTranscript {
    @Guide(description: "The dictated text with filler words, false starts, and repeated words removed and punctuation/capitalization fixed. Same words, meaning, and tone otherwise; any question kept word-for-word. No preamble, no quotes, no commentary.")
    var text: String
}
#endif

enum LocalIntelligenceError: Error, LocalizedError {
    case unavailable
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: return "On-device model not available on this Mac"
        case .emptyResponse: return "On-device model returned no text"
        }
    }
}
