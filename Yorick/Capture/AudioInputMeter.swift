import Foundation

struct AudioMeterReading: Sendable {
    let level: Float
    let showSilenceWarning: Bool
}

/// Measures exactly the mono PCM written to the recording. Display calibration
/// and input health are independent: a quiet voice is still arriving audio.
struct AudioInputMeter {
    private var visualLevel = AudioVisualLevel()
    private var silentDuration: TimeInterval = 0

    mutating func update(samples: [Int16], sampleRate: Double) -> AudioMeterReading? {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0 else { return nil }
        var energy = 0.0
        var peak = 0
        for sample in samples {
            let normalized = Double(sample) / 32768
            energy += normalized * normalized
            peak = max(peak, abs(Int(sample)))
        }
        let rms = Float(sqrt(energy / Double(samples.count)))
        let duration = Double(samples.count) / sampleRate

        // Near-digital silence only: -80 dBFS RMS and -70 dBFS peak.
        // Count every recorded buffer, not a once-a-second meter snapshot that
        // can repeatedly land between words. Missing buffers have a separate
        // watchdog in AudioCapture.
        if rms < 0.0001, Float(peak) / 32768 < 0.000316228 {
            silentDuration += duration
        } else {
            silentDuration = 0
        }

        return AudioMeterReading(
            level: visualLevel.update(rms: rms, duration: duration),
            showSilenceWarning: silentDuration >= 10 - 1e-9
        )
    }
}
