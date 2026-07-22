import AVFoundation
import Foundation

/// Client for the local whisper-server (whisper.cpp HTTP server).
/// Keeps the model in memory for instant transcription — no cold start.
enum WhisperServer {
    private static let serverURL = "http://127.0.0.1:8178"
    private static let inferenceURL = URL(string: "\(serverURL)/inference")!

    /// Vocabulary hint — biases Whisper toward expected proper nouns and product
    /// names. Shared by the server and the whisper-cli fallback so transcription
    /// quality doesn't silently change when the fallback fires.
    static let vocabularyPrompt = "InfuseFlow, Yorick, Claude, Claude Code, SafeYum, Supabase, SwiftUI, Xcode"

    /// The spawned server process, retained so we can terminate it on app quit.
    /// An orphaned server survives the app and can serve a stale model after an
    /// update. Accessed from the launch task and applicationWillTerminate only.
    nonisolated(unsafe) private static var serverProcess: Process?

    /// Path to the bundled whisper-server binary inside the app bundle.
    private static var serverPath: String {
        Bundle.main.resourcePath! + "/Whisper/whisper-server"
    }

    /// Directory where downloaded models live (the app-support root).
    private static var modelDirectory: URL {
        AppPaths.root
    }

    /// Path to the whisper model. Downloaded on first launch to Application Support.
    ///
    /// large-v3-turbo (q5_0): a pruned 4-layer decoder makes it dramatically
    /// faster than `medium` while matching large-v3 English accuracy, and the
    /// q5_0 quantization is ~574 MB vs medium's ~1.5 GB — smaller, faster, and
    /// more accurate all at once.
    static var modelPath: String {
        modelDirectory.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path
    }

    static let modelURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
    static let modelSize: Int64 = 574_041_195 // ~574 MB

    // MARK: - Voice Activity Detection model

    /// Silero VAD model. Lets whisper-server skip silent spans before decoding —
    /// dictation is often 20-50% pauses, so this is a near-1:1 latency win on the
    /// non-speech portion and also suppresses silence hallucinations at the source.
    static var vadModelPath: String {
        modelDirectory.appendingPathComponent("ggml-silero-v5.1.2.bin").path
    }

    static let vadModelURL = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
    static let vadModelSize: Int64 = 885_098 // ~865 KB

    static var isVADInstalled: Bool {
        FileManager.default.fileExists(atPath: vadModelPath)
    }

    /// Remove superseded model files (e.g. the old 1.5 GB medium model) so the
    /// turbo swap doesn't silently leave large orphans in Application Support.
    static func cleanupLegacyModels() {
        let legacy = ["ggml-medium.bin"]
        for name in legacy {
            let path = modelDirectory.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
                print("[WhisperServer] Removed legacy model \(name)")
            }
        }
    }

    /// VAD command-line arguments, empty if the VAD model isn't present so the
    /// server still starts cleanly without it.
    static func vadArguments() -> [String] {
        guard isVADInstalled else { return [] }
        return [
            "--vad",
            "-vm", vadModelPath,
            // Keep a little silence between segments so word onsets aren't clipped.
            "--vad-speech-pad-ms", "60",
        ]
    }

    /// Threads to hand whisper. On Apple Silicon, the performance-core count is
    /// the sweet spot — going past it spills onto slow efficiency cores. Falls
    /// back to a conservative cap on other hardware.
    static var recommendedThreadCount: Int {
        var count = 0
        var size = MemoryLayout<Int>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return count
        }
        return max(4, min(ProcessInfo.processInfo.activeProcessorCount - 2, 8))
    }

    /// Whether the server binary is bundled and the model has been downloaded.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: serverPath) &&
        FileManager.default.fileExists(atPath: modelPath)
    }

    /// Whether just the binary is bundled (model may not be downloaded yet).
    static var isBundled: Bool {
        FileManager.default.fileExists(atPath: serverPath)
    }

    /// Ensure the server is running. Starts it if not.
    static func ensureRunning() {
        guard isInstalled else { return }

        // Check if already running
        if (try? String(contentsOf: URL(string: "\(serverURL)/")!, encoding: .utf8)) != nil {
            print("[WhisperServer] Already running on port 8178")
            return
        }

        // Set up environment so the bundled dylibs and backends are found
        let whisperDir = Bundle.main.resourcePath! + "/Whisper"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.arguments = [
            "-m", modelPath,
            "--port", "8178",
            "-t", "\(recommendedThreadCount)",
            "-l", "en",
        ] + vadArguments()
        print("[WhisperServer] Launch args: \(process.arguments?.joined(separator: " ") ?? "")")

        // Set DYLD path so the server finds its bundled libraries
        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = whisperDir + "/lib"
        process.environment = env

        // Drain stderr continuously. whisper-server logs every inference there;
        // once the ~64 KB pipe buffer fills, the server blocks on write(2)
        // mid-inference and hangs forever — every later transcription then times
        // out and degrades to the cold whisper-cli path until app relaunch.
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where line.lowercased().contains("error") || line.lowercased().contains("failed") {
                print("[whisper-server] \(line.prefix(300))")
            }
        }

        do {
            try process.run()
            serverProcess = process
            print("[WhisperServer] Process started, loading model (\(modelPath))...")

            // Wait for the server to become ready — model takes 5-15s to load
            for i in 1...30 {
                Thread.sleep(forTimeInterval: 1)
                if (try? String(contentsOf: URL(string: "\(serverURL)/")!, encoding: .utf8)) != nil {
                    print("[WhisperServer] Ready after \(i)s")
                    return
                }
                if i % 5 == 0 {
                    print("[WhisperServer] Still loading... (\(i)s)")
                }
                // Check if process died
                if !process.isRunning {
                    print("[WhisperServer] Process died — see [whisper-server] log lines above")
                    serverProcess = nil
                    return
                }
            }
            print("[WhisperServer] Timed out waiting for server (30s)")
        } catch {
            print("[WhisperServer] Failed to start: \(error)")
        }
    }

    /// Terminate the spawned server. Call from applicationWillTerminate so an
    /// orphaned server can't outlive the app and serve a stale model later.
    static func shutdown() {
        guard let process = serverProcess, process.isRunning else { return }
        process.terminate()
        serverProcess = nil
        print("[WhisperServer] Server terminated on app quit")
    }

    /// Download the whisper model if not present. Returns progress via callback.
    static func downloadModelIfNeeded(onProgress: @Sendable @escaping (Double) -> Void) async throws {
        guard !FileManager.default.fileExists(atPath: modelPath) else { return }

        // Create directory
        let dir = (modelPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        print("[WhisperServer] Downloading model...")

        let url = URL(string: modelURL)!
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)

        let totalBytes = (response as? HTTPURLResponse)
            .flatMap { Int64($0.value(forHTTPHeaderField: "Content-Length") ?? "") } ?? modelSize

        let tempPath = modelPath + ".download"
        FileManager.default.createFile(atPath: tempPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tempPath))

        var downloadedBytes: Int64 = 0
        var buffer = Data()
        let chunkSize = 1024 * 1024 // 1MB chunks

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                handle.write(buffer)
                downloadedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let progress = Double(downloadedBytes) / Double(totalBytes)
                await MainActor.run { onProgress(progress) }
            }
        }
        if !buffer.isEmpty {
            handle.write(buffer)
        }
        handle.closeFile()

        // Atomic move
        try FileManager.default.moveItem(atPath: tempPath, toPath: modelPath)
        print("[WhisperServer] Model downloaded to \(modelPath)")
        await MainActor.run { onProgress(1.0) }
    }

    /// Download the small Silero VAD model if missing. Best-effort — a failure
    /// just means the server starts without VAD (slower, but fully functional).
    static func downloadVADModelIfNeeded() async {
        guard !isVADInstalled else { return }
        guard let url = URL(string: vadModelURL) else { return }

        do {
            try FileManager.default.createDirectory(atPath: modelDirectory.path, withIntermediateDirectories: true)
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let destination = URL(fileURLWithPath: vadModelPath)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            print("[WhisperServer] VAD model downloaded to \(vadModelPath)")
        } catch {
            print("[WhisperServer] VAD model download failed (continuing without VAD): \(error)")
        }
    }

    /// Transcribe a WAV file using the running server.
    /// Returns both the full transcript and timestamped segments.
    static func transcribe(audioURL: URL) async throws -> TranscribeResponse {
        let boundary = UUID().uuidString
        var request = URLRequest(url: inferenceURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // The server sends zero bytes until the whole file is decoded, so the
        // idle timeout is effectively a wall-clock cap. Scale it with audio
        // duration — a fixed 60s aborted any recording over ~5-8 minutes
        // mid-decode and forced a full second transcription via cold whisper-cli.
        request.timeoutInterval = max(120, audioDurationSeconds(audioURL) * 2.0)

        var body = Data()

        let audioData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Request verbose_json to get timestamped segments
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("verbose_json\r\n".data(using: .utf8)!)

        // Vocabulary hint — biases Whisper toward expected proper nouns and product names
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(vocabularyPrompt)\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WhisperServerError.requestFailed
        }

        // Parse verbose_json response which includes segments with timestamps
        struct WhisperSegment: Decodable {
            let t0: Int?        // start time in centiseconds
            let t1: Int?        // end time in centiseconds
            let text: String?

            // whisper.cpp also uses these field names in some versions
            let start: Double?
            let end: Double?
        }
        struct WhisperVerboseResponse: Decodable {
            let text: String
            let segments: [WhisperSegment]?
        }

        let result = try JSONDecoder().decode(WhisperVerboseResponse.self, from: data)

        let segments: [TranscriptSegment] = (result.segments ?? []).map { seg in
            // whisper.cpp returns t0/t1 in centiseconds (10ms units)
            let startSec = seg.start ?? (seg.t0.map { Double($0) / 100.0 })
            let endSec = seg.end ?? (seg.t1.map { Double($0) / 100.0 })
            return TranscriptSegment(
                timestamp: startSec,
                endTimestamp: endSec,
                text: seg.text
            )
        }

        print("[WhisperServer] Got \(segments.count) timestamped segments")

        return TranscribeResponse(
            transcript: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            transcriptSegments: segments
        )
    }

    private static func audioDurationSeconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url),
              file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

enum WhisperServerError: Error, LocalizedError {
    case requestFailed
    case notRunning

    var errorDescription: String? {
        switch self {
        case .requestFailed: return "Whisper server request failed"
        case .notRunning: return "Whisper server is not running"
        }
    }
}
