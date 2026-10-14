import Foundation

/// Display-only automatic gain, shared by the pill and the skull's eyes.
/// Learns the recent quiet and loud levels so microphone gain doesn't dictate
/// animation height. Never applies gain to recorded samples.
struct AudioVisualLevel {
    private(set) var value: Float = 0

    // Fixed-duration bins make calibration independent of the microphone's
    // sample rate and callback size. Six seconds includes pauses in speech;
    // percentiles keep one loud click from flattening the following words.
    private static let binDuration = 0.05
    private static let historyCount = 120
    private var history: [Float] = []
    private var nextBin = 0
    private var binEnergy = 0.0
    private var binSeconds = 0.0
    private var floorDB: Float = -75
    private var referenceDB: Float = -20

    mutating func update(rms: Float, duration: TimeInterval) -> Float {
        guard duration.isFinite, duration > 0 else { return value }
        let amplitude = rms.isFinite ? min(1, max(0, rms)) : 0
        let db = amplitude > 0 ? 20 * log10f(amplitude) : -100
        var remaining = duration
        while remaining > 0 {
            let step = min(remaining, Self.binDuration - binSeconds)
            binEnergy += Double(amplitude * amplitude) * step
            binSeconds += step
            remaining -= step
            if binSeconds >= Self.binDuration - 1e-9 {
                let binRMS = Float(sqrt(binEnergy / binSeconds))
                let binDB = binRMS > 0 ? 20 * log10f(binRMS) : -100
                if history.count < Self.historyCount {
                    history.append(binDB)
                } else {
                    history[nextBin] = binDB
                }
                nextBin = (nextBin + 1) % Self.historyCount
                binEnergy = 0
                binSeconds = 0
                calibrate()
            }
        }

        let target = max(0, min(1, 0.85 * (db - floorDB) / (referenceDB - floorDB)))
        let timeConstant = target > value ? 0.045 : 0.18
        let smoothing = Float(1 - exp(-duration / timeConstant))
        value += smoothing * (target - value)
        if value < 0.01 { value = 0 }
        return value
    }

    private mutating func calibrate() {
        guard history.count >= 6 else { return } // First 300 ms: use the broad default range.
        let sorted = history.sorted()
        let quiet = sorted[Int(Double(sorted.count - 1) * 0.10)]
        let loud = sorted[Int(Double(sorted.count - 1) * 0.90)]
        // Leave room above the background and require a real dynamic range.
        // A steady noise floor must not grow into a full-height animation.
        floorDB = max(-75, quiet + 3)
        referenceDB = max(floorDB + 12, loud)
    }
}
