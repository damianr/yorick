import Foundation
import Speech
import AVFoundation

/// Apple's modern on-device speech-to-text via `SpeechAnalyzer` / `SpeechTranscriber`
/// (macOS 26+). Unlike the legacy `SFSpeechRecognizer` path, this is purpose-built
/// for long-form, file-based audio (no ~1-minute truncation) and is roughly 2x
/// faster than Whisper large-turbo — a speed-first engine for users on macOS 26.
///
/// Tradeoffs vs the bundled Whisper model: comparable-but-slightly-lower accuracy
/// (~Whisper small tier) and no custom-vocabulary biasing, so Whisper remains the
/// accuracy-first default and the fallback when this is unavailable.
@available(macOS 26, *)
enum AppleSpeechAnalyzer {
    private static let localeIdentifier = "en-US"

    /// Whether the device can run an English transcriber (model installable).
    static func isSupported() async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.language.languageCode?.identifier == "en" }
    }

    /// Transcribe a recorded WAV file end-to-end.
    static func transcribe(audioURL: URL) async throws -> TranscribeResponse {
        let locale = Locale(identifier: localeIdentifier)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        try await ensureModelInstalled(transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: audioURL)

        // Consume the results stream concurrently with analysis.
        async let collected = collectResults(from: transcriber)

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let (text, segments) = try await collected
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[AppleSpeechAnalyzer] Transcribed: \(trimmed.prefix(100))... (\(segments.count) segments)")
        return TranscribeResponse(transcript: trimmed, transcriptSegments: segments)
    }

    private static func collectResults(
        from transcriber: SpeechTranscriber
    ) async throws -> (String, [TranscriptSegment]) {
        var text = ""
        var segments: [TranscriptSegment] = []

        for try await result in transcriber.results {
            let piece = String(result.text.characters).trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }

            if !text.isEmpty { text += " " }
            text += piece

            let range = result.range
            segments.append(TranscriptSegment(
                timestamp: range.start.seconds,
                endTimestamp: range.end.seconds,
                text: piece
            ))
        }

        return (text, segments)
    }

    /// Ensure the on-device model assets for this transcriber are installed.
    /// Assets live in a system-wide catalog (no app-size cost) and download on
    /// first use.
    private static func ensureModelInstalled(_ transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
}
