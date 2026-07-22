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
    static func cleanupTranscript(_ transcript: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
                You clean up dictated text. Remove filler words (um, uh, you know, \
                like when used as filler), false starts, and immediate word \
                repetitions. Fix punctuation and capitalization. Preserve the \
                speaker's wording, meaning, and tone — do NOT summarize, rephrase, \
                or shorten beyond removing disfluencies. Reply with ONLY the \
                cleaned text, no preamble.
                """)
            let response = try await session.respond(to: transcript)
            let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw LocalIntelligenceError.emptyResponse }
            return cleaned
        }
        #endif
        throw LocalIntelligenceError.unavailable
    }
}

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
