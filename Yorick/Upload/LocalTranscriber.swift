import Foundation

/// Transcribes audio locally using whisper-cli (whisper.cpp) when available.
/// Uses bundled binary from app Resources, falls back to /opt/homebrew.
enum LocalTranscriber {
    /// Path to the bundled whisper-cli, or the Homebrew fallback.
    private static var whisperCLI: String {
        let bundled = Bundle.main.resourcePath! + "/Whisper/whisper-cli"
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
        return "/opt/homebrew/bin/whisper-cli"
    }

    /// Uses the same model path as WhisperServer.
    private static var modelPath: String { WhisperServer.modelPath }

    /// Whether local transcription is available (whisper-cli + model).
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: whisperCLI) &&
        FileManager.default.fileExists(atPath: modelPath)
    }

    /// Transcribe a WAV audio file locally using whisper.cpp.
    static func transcribe(audioURL: URL) async throws -> TranscribeResponse {
        guard audioURL.pathExtension.lowercased() == "wav" else {
            throw TranscriberError.unsupportedFormat
        }

        let jsonOutputPath = audioURL.path + ".json"
        defer { try? FileManager.default.removeItem(atPath: jsonOutputPath) }

        let whisperDir = Bundle.main.resourcePath! + "/Whisper"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperCLI)
        process.arguments = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-oj",           // Output JSON
            "--no-prints",   // Suppress progress output
            "-t", "\(WhisperServer.recommendedThreadCount)",
            "-l", "en",      // English
            // Same vocabulary bias as the server path — fallback quality must
            // not silently differ on proper nouns.
            "--prompt", WhisperServer.vocabularyPrompt,
        ] + WhisperServer.vadArguments()

        // Set DYLD path for bundled libraries
        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = whisperDir + "/lib"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // waitUntilExit() would pin a cooperative-pool thread for the full
        // (minutes-long) CLI run; suspend on the termination handler instead.
        // Handler is installed before run() so a fast exit can't be missed.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TranscriberError.whisperFailed(output)
        }

        let jsonData = try Data(contentsOf: URL(fileURLWithPath: jsonOutputPath))
        let whisperOutput = try JSONDecoder().decode(WhisperOutput.self, from: jsonData)

        let fullText = whisperOutput.transcription
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")

        let segments = whisperOutput.transcription.map { segment in
            TranscriptSegment(
                timestamp: parseTimestamp(segment.timestamps.from),
                endTimestamp: parseTimestamp(segment.timestamps.to),
                text: segment.text.trimmingCharacters(in: .whitespaces)
            )
        }

        return TranscribeResponse(transcript: fullText, transcriptSegments: segments)
    }

    private static func parseTimestamp(_ ts: String) -> Double {
        let parts = ts.split(separator: ":")
        guard parts.count == 3 else { return 0 }
        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        let seconds = Double(parts[2]) ?? 0
        return hours * 3600 + minutes * 60 + seconds
    }
}

// MARK: - Whisper JSON Output Model

private struct WhisperOutput: Decodable {
    let transcription: [WhisperSegment]
}

private struct WhisperSegment: Decodable {
    let timestamps: WhisperTimestamps
    let text: String
}

private struct WhisperTimestamps: Decodable {
    let from: String
    let to: String
}

enum TranscriberError: Error, LocalizedError {
    case whisperFailed(String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .whisperFailed(let output): return "Whisper transcription failed: \(output)"
        case .unsupportedFormat: return "Audio file must be WAV format"
        }
    }
}
