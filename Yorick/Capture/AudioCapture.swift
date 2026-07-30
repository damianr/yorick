import AVFoundation
import CoreMedia
import os

// MARK: - WAV File Writer

/// Writes raw PCM samples directly to a WAV file. No AVAudioFile, no AudioConverter.
final class WAVFileWriter {
    private let handle: FileHandle
    private let url: URL
    private let sampleRate: Int
    private let channels: Int
    private let bitsPerSample: Int
    private var dataSize: UInt32 = 0

    init?(url: URL, sampleRate: Int, channels: Int, bitsPerSample: Int) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample

        // Write placeholder header (44 bytes), will be finalized later
        let header = Data(count: 44)
        do {
            try header.write(to: url)
            self.handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
        } catch {
            print("[WAVWriter] Failed to create file: \(error)")
            return nil
        }
    }

    func write(_ samples: [Int16]) {
        samples.withUnsafeBufferPointer { buffer in
            let data = Data(buffer: buffer)
            handle.write(data)
            dataSize += UInt32(data.count)
        }
    }

    func finalize() {
        handle.seek(toFileOffset: 0)

        let byteRate = UInt32(sampleRate * channels * bitsPerSample / 8)
        let blockAlign = UInt16(channels * bitsPerSample / 8)
        let fileSize = dataSize + 36

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(uint32: fileSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(uint32: 16)                           // chunk size
        header.append(uint16: 1)                            // PCM format
        header.append(uint16: UInt16(channels))
        header.append(uint32: UInt32(sampleRate))
        header.append(uint32: byteRate)
        header.append(uint16: blockAlign)
        header.append(uint16: UInt16(bitsPerSample))
        header.append(contentsOf: "data".utf8)
        header.append(uint32: dataSize)

        handle.write(header)
        handle.closeFile()
        print("[WAVWriter] Finalized: \(dataSize) bytes of audio data")
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }
    mutating func append(uint32 value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case permissionDenied
    case noDevice

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied. Grant permission in System Settings > Privacy & Security > Microphone."
        case .noDevice:
            return "No audio input device found."
        }
    }
}

/// Records audio from a specific (or default) input device using AVCaptureSession.
/// Writes raw PCM to a WAV file — no AVAudioFile, no AudioConverter, no format conversion.
final class AudioCapture: NSObject, @unchecked Sendable {
    private var captureSession: AVCaptureSession?
    private var wavWriter: WAVFileWriter?
    private var fileURL: URL?
    private var isActive = false
    private let captureQueue = DispatchQueue(label: "com.heyyorick.audio-capture")
    private var smoothedLevel: Float = 0

    var onLevelUpdate: (@Sendable (Float) -> Void)?

    /// Spin-up diagnostics: speech between the hotkey and the FIRST sample
    /// buffer is never captured — AVCaptureSession.startRunning is the
    /// dominant cost and gets slower when the device renegotiates (voice
    /// isolation re-engaging around app switches; field reports of swallowed
    /// first words). Measure it in the field:
    ///   log show --process Yorick --last 1h | grep audioSpinup
    private static let spinupLog = Logger(subsystem: "com.heyyorick.Yorick", category: "audioSpinup")
    private var spinupStart: ContinuousClock.Instant?

    func start(preferredDeviceUID: String? = nil) async throws -> URL {
        cleanStop()
        spinupStart = ContinuousClock.now

        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            granted = false
        }
        guard granted else { throw AudioCaptureError.permissionDenied }

        let device: AVCaptureDevice
        if let uid = preferredDeviceUID,
           let preferred = AVCaptureDevice(uniqueID: uid) {
            device = preferred
        } else {
            guard let defaultDevice = AVCaptureDevice.default(for: .audio) else {
                throw AudioCaptureError.noDevice
            }
            device = defaultDevice
        }

        let session = AVCaptureSession()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AudioCaptureError.noDevice }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else { throw AudioCaptureError.noDevice }
        session.addOutput(output)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")

        self.captureSession = session
        self.wavWriter = nil
        self.fileURL = url
        self.smoothedLevel = 0
        self.isActive = true

        session.startRunning()
        print("[AudioCapture] start() → session running, file=\(url.lastPathComponent)")

        return url
    }

    func stop() -> URL? {
        let url = cleanStop()
        if let url {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("[AudioCapture] stop() → \(url.lastPathComponent) size=\(size) bytes")
        }
        return url
    }

    // MARK: - Private

    @discardableResult
    private func cleanStop() -> URL? {
        isActive = false

        captureSession?.stopRunning()
        captureQueue.sync {} // drain any in-flight callbacks
        captureSession = nil

        // Finalize WAV header with actual data size, then close
        wavWriter?.finalize()
        wavWriter = nil

        let url = fileURL
        fileURL = nil
        return url
    }

    private func computeLevel(from sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return }

        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
        guard bytesPerSample > 0 else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &dataPointer) == noErr,
              let rawData = dataPointer, length > 0
        else { return }

        var sum: Float = 0
        let frameCount = numSamples
        let stride = isNonInterleaved ? 1 : channels

        if isFloat && bytesPerSample == 4 {
            rawData.withMemoryRebound(to: Float.self, capacity: frameCount * stride) { floats in
                for f in 0..<frameCount {
                    let s = floats[f * stride]
                    sum += s * s
                }
            }
        } else if bytesPerSample == 2 {
            rawData.withMemoryRebound(to: Int16.self, capacity: frameCount * stride) { shorts in
                for f in 0..<frameCount {
                    let s = Float(shorts[f * stride]) / 32768.0
                    sum += s * s
                }
            }
        } else {
            return
        }

        let rms = sqrtf(sum / Float(max(frameCount, 1)))
        guard rms > 0 else { onLevelUpdate?(0); return }

        let db = 20.0 * log10f(rms)
        let floor: Float = -35
        let ceiling: Float = -6
        let raw = max(0, min(1, (db - floor) / (ceiling - floor)))

        let alpha: Float = raw > smoothedLevel ? 0.4 : 0.15
        smoothedLevel = smoothedLevel + alpha * (raw - smoothedLevel)

        let level = smoothedLevel < 0.05 ? Float(0) : smoothedLevel
        onLevelUpdate?(level)
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isActive else { return }

        if let started = spinupStart {
            spinupStart = nil
            let elapsed = (ContinuousClock.now - started).components
            let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            Self.spinupLog.notice("firstBuffer ms=\(String(format: "%.0f", ms), privacy: .public)")
        }

        // Create WAV writer lazily from first sample's format
        if wavWriter == nil, let url = fileURL {
            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
            else { return }

            // Write mono 16-bit PCM at the device's sample rate — most compatible with Whisper
            let sampleRate = Int(asbd.mSampleRate)
            wavWriter = WAVFileWriter(url: url, sampleRate: sampleRate, channels: 1, bitsPerSample: 16)
            print("[AudioCapture] WAV writer created: \(sampleRate)Hz mono 16-bit")
        }

        guard let wavWriter else { return }

        // Extract raw audio data and convert to mono 16-bit PCM
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &dataPointer) == noErr,
              let srcData = dataPointer, length > 0
        else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        // Convert to mono Int16 samples
        var monoSamples = [Int16](repeating: 0, count: frameCount)

        if isFloat {
            srcData.withMemoryRebound(to: Float.self, capacity: frameCount * channels) { floats in
                let stride = isNonInterleaved ? 1 : channels
                for f in 0..<frameCount {
                    let sample = floats[f * stride]
                    monoSamples[f] = Int16(max(-1, min(1, sample)) * 32767)
                }
            }
        } else {
            srcData.withMemoryRebound(to: Int16.self, capacity: frameCount * channels) { shorts in
                let stride = isNonInterleaved ? 1 : channels
                for f in 0..<frameCount {
                    monoSamples[f] = shorts[f * stride]
                }
            }
        }

        wavWriter.write(monoSamples)

        computeLevel(from: sampleBuffer)
    }
}
