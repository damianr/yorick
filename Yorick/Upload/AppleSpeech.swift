import Foundation
import Speech

/// Apple's on-device speech recognition via SFSpeechRecognizer.
/// Better punctuation, question detection, and short utterance handling than Whisper.
/// Runs on Apple's Neural Engine — no model download needed.
enum AppleSpeech {
    private nonisolated(unsafe) static let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// Whether speech recognition is available and authorized.
    static var isAvailable: Bool {
        guard let recognizer, recognizer.isAvailable else { return false }
        guard recognizer.supportsOnDeviceRecognition else { return false }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Request authorization for speech recognition.
    /// Must be called before first use — shows a system permission dialog.
    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribe a WAV audio file using on-device Apple speech recognition.
    static func transcribe(audioURL: URL) async throws -> TranscribeResponse {
        guard let recognizer, recognizer.isAvailable else {
            throw AppleSpeechError.notAvailable
        }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw AppleSpeechError.notAuthorized
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true  // Collect all results including partials
        request.taskHint = .dictation
        request.contextualStrings = [
            "Yorick",
            "Whisper",
            "Codex",
            "Xcode"
        ]

        // Enable punctuation (macOS 13+)
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }

        // Collect results — Apple Speech may fire multiple times for pauses.
        // We want the LAST result (most complete), whether final or not.
        let (transcript, segments) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, [TranscriptSegment]), Error>) in
            var lastText = ""
            var lastSegments: [TranscriptSegment] = []
            var resumed = false

            recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    lastText = result.bestTranscription.formattedString
                    lastSegments = result.bestTranscription.segments.map { seg in
                        TranscriptSegment(
                            timestamp: seg.timestamp,
                            endTimestamp: seg.timestamp + seg.duration,
                            text: seg.substring
                        )
                    }

                    let firstStart = lastSegments.compactMap(\.timestamp).min()
                    if result.isFinal || (firstStart ?? 0) > 3 {
                        print("""
                        [AppleSpeech] Result final=\(result.isFinal) segments=\(lastSegments.count) \
                        coverage=\(coverageSummary(lastSegments)) text=\(lastText.prefix(100))...
                        """)
                    }

                    if result.isFinal && !resumed {
                        resumed = true
                        continuation.resume(returning: (lastText, lastSegments))
                    }
                } else if let error {
                    print("[AppleSpeech] Error: \(error.localizedDescription); partial coverage=\(coverageSummary(lastSegments)) text=\(lastText.prefix(100))...")
                    if !resumed {
                        // If we have partial results, use them instead of failing
                        if !lastText.isEmpty {
                            resumed = true
                            continuation.resume(returning: (lastText, lastSegments))
                        } else {
                            resumed = true
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
        print("[AppleSpeech] Transcribed: \(transcript.prefix(100))... (\(segments.count) segments)")

        return TranscribeResponse(
            transcript: transcript,
            transcriptSegments: segments
        )
    }

    private static func coverageSummary(_ segments: [TranscriptSegment]) -> String {
        let starts = segments.compactMap(\.timestamp)
        let ends = segments.compactMap(\.endTimestamp)
        guard let firstStart = starts.min(), let lastEnd = ends.max() else {
            return "(none)"
        }
        return String(format: "%.1fs-%.1fs", firstStart, lastEnd)
    }
}

enum AppleSpeechError: Error, LocalizedError {
    case notAvailable
    case notAuthorized
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "Apple Speech Recognition not available"
        case .notAuthorized: return "Speech recognition not authorized. Grant permission in System Settings > Privacy & Security > Speech Recognition."
        case .recognitionFailed(let msg): return "Speech recognition failed: \(msg)"
        }
    }
}
