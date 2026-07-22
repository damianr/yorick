import Foundation

enum AudioDebugSettings {
    static let keepAudioKey = "keepDebugAudio"
    static let defaultKeepAudio = false
    static let retainedAudioFileName = "audio.wav"

    static var keepAudio: Bool {
        UserDefaults.standard.bool(forKey: keepAudioKey)
    }
}

enum AudioDiagnosticsAnalyzer {
    static func analyzeWAV(at url: URL, retainedAudioFileName: String?) throws -> AudioDiagnostics {
        let file = try Data(contentsOf: url)
        let wav = try parseWAV(file)
        guard wav.audioFormat == 1 else { throw AudioDiagnosticsError.unsupportedFormat("Only PCM WAV is supported") }
        guard wav.bitsPerSample == 16 else { throw AudioDiagnosticsError.unsupportedFormat("Only 16-bit WAV is supported") }
        guard wav.channelCount > 0, wav.sampleRate > 0 else { throw AudioDiagnosticsError.invalidWAV }

        let bytesPerSample = wav.bitsPerSample / 8
        let bytesPerFrame = bytesPerSample * wav.channelCount
        let frameCount = wav.dataRange.count / bytesPerFrame
        guard frameCount > 0 else { throw AudioDiagnosticsError.noSamples }

        // Bulk-read channel 0 of every frame. The previous per-sample Data
        // subscript loop was ~10-50x slower and cost seconds on long recordings.
        let byteCount = frameCount * bytesPerFrame
        let dataSlice = file.subdata(in: wav.dataRange.lowerBound..<(wav.dataRange.lowerBound + byteCount))
        var samples = [Int16](repeating: 0, count: frameCount)
        dataSlice.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for frame in 0..<frameCount {
                samples[frame] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frame * bytesPerFrame, as: Int16.self))
            }
        }

        return analyzeSamples(
            samples,
            sampleRate: wav.sampleRate,
            channelCount: wav.channelCount,
            bitDepth: wav.bitsPerSample,
            retainedAudioFileName: retainedAudioFileName
        )
    }

    private static func analyzeSamples(
        _ samples: [Int16],
        sampleRate: Int,
        channelCount: Int,
        bitDepth: Int,
        retainedAudioFileName: String?
    ) -> AudioDiagnostics {
        let fullScale = 32768.0
        let duration = Double(samples.count) / Double(sampleRate)

        var squareSum = 0.0
        var total = 0.0
        var clipped = 0
        var peak = 0
        for sample in samples {
            let value = Double(sample)
            squareSum += value * value
            total += value
            let magnitude = abs(Int(sample))
            if magnitude >= 32760 { clipped += 1 }
            if magnitude > peak { peak = magnitude }
        }
        let peakLinear = Double(peak) / fullScale

        let rmsLinear = sqrt(squareSum / Double(samples.count)) / fullScale
        let dcOffset = (total / Double(samples.count)) / fullScale * 100.0
        let clippedPercent = Double(clipped) / Double(samples.count) * 100.0
        let zeroCrossings = zeroCrossingRate(samples, duration: duration)

        let frameLength = max(1, Int(Double(sampleRate) * 0.02))
        let frameRMS = stride(from: 0, to: samples.count, by: frameLength).map { start -> Double in
            let end = min(start + frameLength, samples.count)
            var sum = 0.0
            for index in start..<end {
                let value = Double(samples[index])
                sum += value * value
            }
            return sqrt(sum / Double(max(end - start, 1))) / fullScale
        }

        let noiseFloor = percentile(frameRMS, 0.10)
        let loudSpeech = percentile(frameRMS, 0.90)
        let activeThreshold = max(noiseFloor * 3.5, pow(10.0, -45.0 / 20.0))
        let activeFrames = frameRMS.filter { $0 >= activeThreshold }
        let activeFramePercent = frameRMS.isEmpty ? 0 : Double(activeFrames.count) / Double(frameRMS.count) * 100.0
        let activeRMS = activeFrames.isEmpty ? 0 : sqrt(activeFrames.reduce(0.0) { $0 + $1 * $1 } / Double(activeFrames.count))
        let nearSilentPercent = frameRMS.isEmpty ? 0 : Double(frameRMS.filter { (dbFS($0) ?? -Double.infinity) < -60.0 }.count) / Double(frameRMS.count) * 100.0

        var notes: [String] = []
        let peakDB = dbFS(peakLinear)
        let activeDB = dbFS(activeRMS)
        let noiseDB = dbFS(noiseFloor)
        let signalToNoiseDB: Double?
        if let activeDB, let noiseDB {
            signalToNoiseDB = activeDB - noiseDB
        } else {
            signalToNoiseDB = nil
        }

        if peakLinear == 0 {
            notes.append("No measurable audio reached the app.")
        } else if (peakDB ?? -Double.infinity) < -25 {
            notes.append("Peak is very low; mic gain, distance, or acoustic path may be limiting recognition.")
        } else if (peakDB ?? -Double.infinity) > -1 {
            notes.append("Peak is extremely hot; clipping or compression may hurt recognition.")
        }

        if let activeDB, !activeFrames.isEmpty, activeDB < -30 {
            notes.append("Speech RMS is very low; more gain, closer placement, or a better mic opening may help.")
        } else if let activeDB, !activeFrames.isEmpty, activeDB < -24 {
            notes.append("Speech RMS is low; recognition may be inconsistent without more usable level.")
        } else if let activeDB, activeDB > -12 {
            notes.append("Speech RMS is high; reducing gain could improve clarity.")
        }

        if clippedPercent > 0.02 {
            notes.append("Clipping is present; lower firmware gain or increase mic distance.")
        }

        if let noiseDB, noiseDB > -45 {
            notes.append("Noise floor is high; enclosure, RF/audio artifacts, or gain may be hurting recognition.")
        }

        if let signalToNoiseDB {
            if signalToNoiseDB < 12 {
                notes.append("Speech-to-noise margin is poor; Whisper may hear the recording as partial speech or static.")
            } else if signalToNoiseDB < 18 {
                notes.append("Speech-to-noise margin is marginal; small posture changes may cause word errors.")
            }
        }

        if nearSilentPercent > 25, activeFramePercent < 60 {
            notes.append("Much of the file is near silence; check whether speech is being blocked.")
        }

        if zeroCrossings > 3000 {
            notes.append("Zero-crossing rate is high; this can indicate hiss or static-like content.")
        }

        if notes.isEmpty {
            notes.append("Basic levels look reasonable; remaining errors are more likely model, vocabulary, or acoustics.")
        }

        return AudioDiagnostics(
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitDepth: bitDepth,
            durationSeconds: duration,
            peakDBFS: peakDB,
            overallRMSDBFS: dbFS(rmsLinear),
            activeSpeechRMSDBFS: dbFS(activeRMS),
            noiseFloorDBFS: noiseDB,
            percentile90RMSDBFS: dbFS(loudSpeech),
            clippedSampleCount: clipped,
            clippedSamplePercent: clippedPercent,
            dcOffsetPercent: dcOffset,
            activeFramePercent: activeFramePercent,
            nearSilentFramePercent: nearSilentPercent,
            zeroCrossingsPerSecond: zeroCrossings,
            signalToNoiseDB: signalToNoiseDB,
            notes: notes,
            retainedAudioFileName: retainedAudioFileName
        )
    }

    private static func parseWAV(_ data: Data) throws -> WAVMetadata {
        guard data.count >= 44,
              data.asciiString(in: 0..<4) == "RIFF",
              data.asciiString(in: 8..<12) == "WAVE"
        else { throw AudioDiagnosticsError.invalidWAV }

        var offset = 12
        var audioFormat: Int?
        var channelCount: Int?
        var sampleRate: Int?
        var bitsPerSample: Int?
        var dataRange: Range<Int>?

        while offset + 8 <= data.count {
            let id = data.asciiString(in: offset..<(offset + 4))
            let chunkSize = Int(data.uint32LE(at: offset + 4))
            let chunkStart = offset + 8
            let chunkEnd = min(chunkStart + chunkSize, data.count)

            if id == "fmt " {
                guard chunkSize >= 16, chunkStart + 16 <= data.count else {
                    throw AudioDiagnosticsError.invalidWAV
                }
                audioFormat = Int(data.uint16LE(at: chunkStart))
                channelCount = Int(data.uint16LE(at: chunkStart + 2))
                sampleRate = Int(data.uint32LE(at: chunkStart + 4))
                bitsPerSample = Int(data.uint16LE(at: chunkStart + 14))
            } else if id == "data" {
                dataRange = chunkStart..<chunkEnd
            }

            offset = chunkStart + chunkSize + (chunkSize % 2)
        }

        guard let audioFormat, let channelCount, let sampleRate, let bitsPerSample, let dataRange else {
            throw AudioDiagnosticsError.invalidWAV
        }

        return WAVMetadata(
            audioFormat: audioFormat,
            channelCount: channelCount,
            sampleRate: sampleRate,
            bitsPerSample: bitsPerSample,
            dataRange: dataRange
        )
    }

    private static func dbFS(_ value: Double) -> Double? {
        guard value > 0 else { return nil }
        return 20.0 * log10(value)
    }

    private static func percentile(_ values: [Double], _ pct: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let ordered = values.sorted()
        let index = Int((Double(ordered.count - 1) * pct).rounded())
        return ordered[max(0, min(ordered.count - 1, index))]
    }

    private static func zeroCrossingRate(_ samples: [Int16], duration: Double) -> Double {
        guard duration > 0, let first = samples.first else { return 0 }
        var crossings = 0
        var last = first
        for sample in samples.dropFirst() {
            if (last < 0 && sample >= 0) || (last > 0 && sample <= 0) {
                crossings += 1
            }
            if sample != 0 {
                last = sample
            }
        }
        return Double(crossings) / duration
    }
}

private struct WAVMetadata {
    let audioFormat: Int
    let channelCount: Int
    let sampleRate: Int
    let bitsPerSample: Int
    let dataRange: Range<Int>
}

enum AudioDiagnosticsError: Error, LocalizedError {
    case invalidWAV
    case noSamples
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidWAV: return "Invalid WAV file"
        case .noSamples: return "WAV file has no samples"
        case .unsupportedFormat(let message): return message
        }
    }
}

private extension Data {
    func asciiString(in range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= count else { return "" }
        return String(decoding: self[range], as: UTF8.self)
    }

    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
        | (UInt32(self[offset + 1]) << 8)
        | (UInt32(self[offset + 2]) << 16)
        | (UInt32(self[offset + 3]) << 24)
    }

    func int16LE(at offset: Int) -> Int16 {
        Int16(bitPattern: uint16LE(at: offset))
    }
}
