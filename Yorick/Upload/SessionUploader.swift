import AVFoundation
import Foundation

// MARK: - Transcription Types

struct TranscribeResponse: Decodable, Sendable {
    let transcript: String
    let transcriptSegments: [TranscriptSegment]
}

struct TranscriptSegment: Codable, Sendable {
    let timestamp: Double?
    let endTimestamp: Double?
    let text: String?
}

// MARK: - Transcription Engine Selection

enum TranscriptionEngine: String, CaseIterable {
    case whisper = "whisper"
    case apple = "apple"
    case appleAnalyzer = "appleAnalyzer"

    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .apple: return "Apple Speech (Legacy)"
        case .appleAnalyzer: return "Apple Speech (Fast)"
        }
    }

    /// Whether this engine can run on the current OS.
    var isAvailableOnThisOS: Bool {
        switch self {
        case .whisper, .apple:
            return true
        case .appleAnalyzer:
            if #available(macOS 26, *) { return true }
            return false
        }
    }

    /// Engines that should be offered to the user on this machine.
    static var available: [TranscriptionEngine] {
        allCases.filter(\.isAvailableOnThisOS)
    }

    /// Zero-setup default: Apple's on-device SpeechAnalyzer needs no model
    /// download. Whisper stays available as the opt-in accuracy engine.
    static var defaultEngine: TranscriptionEngine {
        if TranscriptionEngine.appleAnalyzer.isAvailableOnThisOS { return .appleAnalyzer }
        return .whisper
    }

    static var preferred: TranscriptionEngine {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "transcriptionEngine") else {
                return defaultEngine
            }
            if let engine = TranscriptionEngine(rawValue: raw) {
                // Don't hand back an engine the current OS can't run.
                return engine.isAvailableOnThisOS ? engine : .whisper
            }

            if let migrated = allCases.first(where: { $0.displayName == raw }) {
                UserDefaults.standard.set(migrated.rawValue, forKey: "transcriptionEngine")
                return migrated
            }

            return defaultEngine
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "transcriptionEngine")
        }
    }
}

// MARK: - Transcription Service

/// Local-only transcription. Supports Whisper (bundled) and Apple Speech (on-device).
enum TranscriptionService {
    static func transcribe(audioURL: URL) async throws -> TranscribeResponse {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        guard fileSize > 0 else { throw TranscriptionError.emptyAudioFile }

        let engine = TranscriptionEngine.preferred
        print("[Transcribe] Preferred engine: \(engine.displayName)")

        // Try preferred engine first, fall back to alternatives
        switch engine {
        case .appleAnalyzer:
            if #available(macOS 26, *), await AppleSpeechAnalyzer.isSupported() {
                do {
                    print("[Transcribe] Using Apple SpeechAnalyzer")
                    return try await AppleSpeechAnalyzer.transcribe(audioURL: audioURL)
                } catch {
                    print("[Transcribe] Apple SpeechAnalyzer failed: \(error), falling back to Whisper")
                    return try await transcribeWithWhisper(audioURL: audioURL)
                }
            } else {
                print("[Transcribe] Apple SpeechAnalyzer unavailable, using Whisper")
                return try await transcribeWithWhisper(audioURL: audioURL)
            }

        case .apple:
            if AppleSpeech.isAvailable {
                print("[Transcribe] Using Apple Speech")
                do {
                    let result = try await AppleSpeech.transcribe(audioURL: audioURL)
                    if isLikelyIncompleteAppleSpeechResult(result, audioURL: audioURL) {
                        print("[Transcribe] Apple Speech result looks incomplete, falling back to Whisper")
                        return try await transcribeWithWhisper(audioURL: audioURL)
                    }
                    return result
                } catch {
                    print("[Transcribe] Apple Speech failed: \(error), falling back to Whisper")
                    return try await transcribeWithWhisper(audioURL: audioURL)
                }
            } else {
                print("[Transcribe] Apple Speech not available, using Whisper")
                return try await transcribeWithWhisper(audioURL: audioURL)
            }

        case .whisper:
            do {
                return try await transcribeWithWhisper(audioURL: audioURL)
            } catch {
                // If all Whisper options fail, try Apple Speech as last resort
                if AppleSpeech.isAvailable {
                    print("[Transcribe] All Whisper options failed, trying Apple Speech")
                    return try await AppleSpeech.transcribe(audioURL: audioURL)
                }
                throw error
            }
        }
    }

    private static func transcribeWithWhisper(audioURL: URL) async throws -> TranscribeResponse {
        // Try WhisperServer first (model stays in memory, fast)
        if WhisperServer.isInstalled {
            print("[Transcribe] Trying WhisperServer...")
            do {
                return try await WhisperServer.transcribe(audioURL: audioURL)
            } catch {
                print("[Transcribe] WhisperServer failed: \(error.localizedDescription)")
                // The server may simply be dead or still loading (e.g. recording
                // started seconds after app launch). Restarting and retrying once
                // is far cheaper than the cold whisper-cli path, which reloads
                // the 574 MB model and transcribes the whole file from scratch.
                await Task.detached { WhisperServer.ensureRunning() }.value
                do {
                    print("[Transcribe] Retrying WhisperServer after ensureRunning...")
                    return try await WhisperServer.transcribe(audioURL: audioURL)
                } catch {
                    print("[Transcribe] WhisperServer retry failed: \(error.localizedDescription)")
                }
            }
        }

        // Fall back to whisper-cli (subprocess, slower but reliable)
        if LocalTranscriber.isAvailable {
            print("[Transcribe] Falling back to LocalTranscriber (whisper-cli)")
            return try await LocalTranscriber.transcribe(audioURL: audioURL)
        }

        // Last resort: try Apple Speech
        if AppleSpeech.isAvailable {
            print("[Transcribe] Falling back to Apple Speech")
            return try await AppleSpeech.transcribe(audioURL: audioURL)
        }

        throw TranscriptionError.noTranscriberAvailable
    }

    private static func isLikelyIncompleteAppleSpeechResult(
        _ result: TranscribeResponse,
        audioURL: URL
    ) -> Bool {
        guard let duration = audioDuration(audioURL), duration >= 8 else { return false }

        let timedSegments = result.transcriptSegments.compactMap { segment -> (start: Double, end: Double)? in
            guard let start = segment.timestamp, let end = segment.endTimestamp else { return nil }
            return (start, end)
        }

        guard !timedSegments.isEmpty else {
            let wordCount = result.transcript.split(whereSeparator: \.isWhitespace).count
            return wordCount <= 3 && duration >= 12
        }

        let firstStart = timedSegments.map(\.start).min() ?? 0
        let lastEnd = timedSegments.map(\.end).max() ?? 0
        let coveredDuration = max(0, lastEnd - firstStart)
        let wordCount = result.transcript.split(whereSeparator: \.isWhitespace).count

        if firstStart > min(3, duration * 0.25) {
            return true
        }

        if coveredDuration < max(2, duration * 0.35), wordCount <= max(4, Int(duration * 0.5)) {
            return true
        }

        return false
    }

    private static func audioDuration(_ audioURL: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: audioURL) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Double(file.length) / sampleRate
    }
}

enum TranscriptionError: Error, LocalizedError {
    case emptyAudioFile
    case noTranscriberAvailable

    var errorDescription: String? {
        switch self {
        case .emptyAudioFile: return "No audio recorded"
        case .noTranscriberAvailable: return "No transcription engine available"
        }
    }
}
