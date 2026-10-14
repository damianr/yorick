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
    private var inputMeter = AudioInputMeter()
    var onMeterUpdate: (@Sendable (AudioMeterReading) -> Void)?
    var onDeviceChanged: (@Sendable (String) -> Void)?
    private var loggedUnsupportedFormat = false
    private static let formatLog = Logger(subsystem: "com.heyyorick.Yorick", category: "audioFormat")

    // MARK: - Keeping the recording alive
    //
    // FIELD-REPORTED: recordings stopped mid-sentence while the key was still
    // held, silently. Nothing here observed AVCaptureSession failing, so when
    // the session died — another app taking the device, a wireless mic
    // dropping or power-saving, a runtime error, a device re-enumerating —
    // `isActive` stayed true, the pill kept saying "Listening…", and the WAV
    // simply stopped growing. On release you got a truncated transcript with
    // no sign anything had gone wrong.
    //
    // Silent truncation is the worst failure this app can have: it is
    // invisible at the moment it matters and only discovered later, when the
    // words are gone. Three layers now stand against it — named notifications
    // for causes we know, a STARVATION WATCHDOG for causes we don't, and a
    // callback so the UI can stop claiming to listen when it isn't.

    /// Fires when audio stops arriving, with a human-readable reason. The
    /// recording is NOT ended — the key is still held, so the contract holds
    /// and Yorick keeps trying.
    var onAudioStalled: (@Sendable (String) -> Void)?
    /// Fires when buffers resume after a stall.
    var onAudioResumed: (@Sendable () -> Void)?

    private let stallLog = Logger(subsystem: "com.heyyorick.Yorick", category: "audioStall")
    /// Last time a sample buffer arrived. Read by the watchdog, written by the
    /// capture queue — a lock rather than an actor because the delegate is a
    /// hot path and must not await anything.
    private let bufferClock = NSLock()
    private var lastBufferAt: ContinuousClock.Instant?
    private var watchdog: DispatchSourceTimer?
    private var stalled = false
    private var preferredUID: String?
    private var observers: [NSObjectProtocol] = []

    /// How long silence-from-the-device counts as normal before it counts as
    /// broken. Long enough that a pause in speech never trips it (buffers keep
    /// arriving during silence — a working mic sends zeros), short enough that
    /// a stall is caught inside a sentence.
    private static let stallThreshold: Duration = .seconds(2)

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
        self.inputMeter = AudioInputMeter()
        self.loggedUnsupportedFormat = false
        self.isActive = true

        self.preferredUID = preferredDeviceUID
        observeFailures(of: session)

        session.startRunning()
        onDeviceChanged?(device.localizedName)
        markBufferArrived()
        startWatchdog()
        print("[AudioCapture] start() → session running, file=\(url.lastPathComponent)")

        return url
    }

    // MARK: Failure detection

    /// The causes macOS will actually tell us about.
    private func observeFailures(of session: AVCaptureSession) {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.handleStall("runtime error: \(error?.localizedDescription ?? "unknown")")
        })
        observers.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil
        ) { [weak self] _ in
            self?.handleStall("another app took the microphone")
        })
        observers.append(center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil
        ) { [weak self] _ in
            self?.attemptRecovery(reason: "interruption ended")
        })
        observers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.handleStall("the microphone disconnected")
        })
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// The catch-all, and the reason this is bulletproof rather than merely
    /// better: it does not care WHY audio stopped. A working microphone sends
    /// buffers continuously — zeros during silence — so a gap means the
    /// pipeline is broken however it broke, including in ways nobody has
    /// thought of yet.
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            bufferClock.lock()
            let last = lastBufferAt
            bufferClock.unlock()
            guard let last else { return }
            if ContinuousClock.now - last > Self.stallThreshold, !stalled {
                handleStall("no audio from the microphone")
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func markBufferArrived() {
        bufferClock.lock()
        lastBufferAt = ContinuousClock.now
        let wasStalled = stalled
        stalled = false
        bufferClock.unlock()
        if wasStalled {
            stallLog.notice("resumed")
            print("[AudioCapture] audio resumed")
            onAudioResumed?()
        }
    }

    private func handleStall(_ reason: String) {
        bufferClock.lock()
        let alreadyStalled = stalled
        stalled = true
        bufferClock.unlock()
        guard !alreadyStalled, isActive else { return }
        stallLog.error("stalled reason=\(reason, privacy: .public)")
        print("[AudioCapture] STALLED: \(reason)")
        onAudioStalled?(reason)
        attemptRecovery(reason: reason)
    }

    /// Rebuild the session and keep writing to the SAME file.
    ///
    /// The WAV writer is deliberately untouched, so recovered audio APPENDS.
    /// There is a gap where the device was gone, but the words after it are
    /// captured — which is the whole point. Truncating at the failure would
    /// throw away everything the user said afterwards, which is what made the
    /// original bug infuriating.
    private func attemptRecovery(reason: String) {
        captureQueue.async { [weak self] in
            guard let self, self.isActive else { return }
            guard let url = self.fileURL else { return }
            self.captureSession?.stopRunning()
            self.captureSession = nil

            guard let device = self.preferredUID.flatMap(AVCaptureDevice.init(uniqueID:))
                    ?? AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                self.stallLog.error("recovery failed: no device")
                return
            }
            let session = AVCaptureSession()
            guard session.canAddInput(input) else {
                self.stallLog.error("recovery failed: cannot add input")
                return
            }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: self.captureQueue)
            guard session.canAddOutput(output) else {
                self.stallLog.error("recovery failed: cannot add output")
                return
            }
            session.addOutput(output)
            self.captureSession = session
            self.observeFailures(of: session)
            self.inputMeter = AudioInputMeter()
            session.startRunning()
            self.onDeviceChanged?(device.localizedName)
            self.stallLog.notice("recovery attempted for \(reason, privacy: .public) file=\(url.lastPathComponent, privacy: .public)")
            print("[AudioCapture] recovery attempted after: \(reason)")
        }
    }

    /// A selected BLE pocket or skull session supplies decoded PCM through this path.
    func startExternal(deviceName: String = PocketBluetoothProtocol.deviceName) throws -> URL {
        cleanStop()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        guard let writer = WAVFileWriter(url: url, sampleRate: 16000, channels: 1, bitsPerSample: 16) else {
            throw AudioCaptureError.noDevice
        }
        fileURL = url; wavWriter = writer; isActive = true; inputMeter = AudioInputMeter()
        onDeviceChanged?(deviceName)
        return url
    }

    func appendExternal(_ samples: [Int16]) {
        guard isActive, captureSession == nil else { return }
        // Synchronous ordering makes the last BLE frame precede WAV finalization.
        captureQueue.sync {
            wavWriter?.write(samples)
            if let reading = inputMeter.update(samples: samples, sampleRate: 16000) { onMeterUpdate?(reading) }
        }
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
        watchdog?.cancel()
        watchdog = nil
        removeObservers()
        bufferClock.lock()
        lastBufferAt = nil
        stalled = false
        bufferClock.unlock()

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

    // MARK: - Format conversion

    /// Down-mix one buffer to mono floats in -1...1.
    ///
    /// FIELD-REPORTED: "No audio detected" with mics that work everywhere
    /// else. This used to keep channel 0 only, and to read every non-float
    /// format as Int16. So a two-transmitter wireless lapel receiver (TX2
    /// arrives on the RIGHT channel), an audio interface with the mic on
    /// input 2, or a mic with the left side unwired recorded pure silence;
    /// and a 24- or 32-bit integer device recorded noise. Now every channel
    /// carrying signal is mixed in, and the sample format is read for what
    /// it is.
    ///
    /// Channels more than 20 dB below the loudest are left out of the mix,
    /// so an unused input's hiss doesn't dilute the one that has the voice.
    static func monoSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        let flags = asbd.mFormatFlags
        guard flags & kAudioFormatFlagIsBigEndian == 0 else { return nil }
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let alignedHigh = flags & kAudioFormatFlagIsAlignedHigh != 0
        let bits = Int(asbd.mBitsPerChannel)
        var channels = max(Int(asbd.mChannelsPerFrame), 1)
        // Bytes one sample of one channel occupies (24-bit audio may sit in
        // a 3- or 4-byte container; mBitsPerChannel alone can't tell which).
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let width = isNonInterleaved ? bytesPerFrame : bytesPerFrame / channels
        guard width > 0 else { return nil }

        // Copy rather than borrow the block buffer's pointer: a block buffer
        // need not be contiguous, and reading past the first segment is
        // undefined. A few KB per buffer is nothing.
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length,
                                         destination: &bytes) == kCMBlockBufferNoErr
        else { return nil }

        // Non-interleaved planes sit back to back; if they don't all fit,
        // fall back to the first plane rather than read past the end.
        if frameCount * channels * width > length {
            channels = 1
            guard frameCount * width <= length else { return nil }
        }

        return bytes.withUnsafeBytes { raw -> [Float]? in
            func sample(at offset: Int) -> Float? {
                switch (isFloat, width) {
                case (true, 4):
                    return raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                case (true, 8):
                    return Float(raw.loadUnaligned(fromByteOffset: offset, as: Double.self))
                case (false, 2):
                    return Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                case (false, 3):
                    let v = Int32(raw[offset]) | Int32(raw[offset + 1]) << 8 | Int32(raw[offset + 2]) << 16
                    return Float((v << 8) >> 8) / 8_388_608
                case (false, 4):
                    let v = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int32.self))
                    if bits >= 32 || alignedHigh { return Float(v) / 2_147_483_648 }
                    return Float((v << 8) >> 8) / 8_388_608 // 24-bit, low-aligned
                default:
                    return nil
                }
            }

            func offset(frame: Int, channel: Int) -> Int {
                isNonInterleaved
                    ? (channel * frameCount + frame) * width
                    : frame * bytesPerFrame + channel * width
            }

            guard sample(at: 0) != nil else { return nil } // unsupported format

            var perChannel = [[Float]](repeating: [Float](repeating: 0, count: frameCount), count: channels)
            var energy = [Float](repeating: 0, count: channels)
            for c in 0..<channels {
                for f in 0..<frameCount {
                    let s = sample(at: offset(frame: f, channel: c)) ?? 0
                    let clamped = s.isFinite ? max(-1, min(1, s)) : 0
                    perChannel[c][f] = clamped
                    energy[c] += clamped * clamped
                }
            }
            if channels == 1 { return perChannel[0] }

            // -20 dB in power is a factor of 100.
            let loudest = energy.max() ?? 0
            let live = (0..<channels).filter { loudest == 0 || energy[$0] * 100 >= loudest }
            var mono = [Float](repeating: 0, count: frameCount)
            for c in live {
                for f in 0..<frameCount { mono[f] += perChannel[c][f] }
            }
            let scale = 1 / Float(live.count)
            for f in 0..<frameCount { mono[f] *= scale }
            return mono
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isActive else { return }
        markBufferArrived()

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
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            // What the device actually hands us — the first thing to check
            // when a mic "isn't heard":
            //   log show --process Yorick --last 1h | grep audioFormat
            Self.formatLog.notice("audioFormat rate=\(sampleRate, privacy: .public) channels=\(asbd.mChannelsPerFrame, privacy: .public) bits=\(asbd.mBitsPerChannel, privacy: .public) bytesPerFrame=\(asbd.mBytesPerFrame, privacy: .public) float=\(isFloat, privacy: .public) nonInterleaved=\(nonInterleaved, privacy: .public)")
            print("[AudioCapture] WAV writer created: \(sampleRate)Hz mono 16-bit from \(asbd.mChannelsPerFrame)ch \(asbd.mBitsPerChannel)-bit\(isFloat ? " float" : "")")
        }

        guard let wavWriter else { return }

        guard let mono = Self.monoSamples(from: sampleBuffer) else {
            if !loggedUnsupportedFormat {
                loggedUnsupportedFormat = true
                Self.formatLog.error("audioFormat unsupported — buffers dropped")
            }
            return
        }

        let pcm = mono.map { Int16($0 * 32767) }
        wavWriter.write(pcm)

        let sampleRate = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48_000
        if let reading = inputMeter.update(samples: pcm, sampleRate: sampleRate) {
            onMeterUpdate?(reading)
        }
    }
}
