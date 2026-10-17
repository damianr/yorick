import XCTest

final class AudioVisualLevelTests: XCTestCase {
    /// A repeating phrase with syllables and pauses, scaled like microphones
    /// with different input gains. Values are dB relative to its loud syllable.
    private func speechDB(at time: Double, peak: Float) -> Float {
        let phase = time.truncatingRemainder(dividingBy: 2)
        if phase < 0.25 || phase > 1.65 { return peak - 30 }
        return peak - 9 + 9 * Float(sin((phase - 0.25) * 2 * .pi * 3))
    }

    @discardableResult
    private func phrase(_ meter: inout AudioVisualLevel, peak: Float,
                        seconds: Double = 8, step: Double = 0.02) -> [Float] {
        (0..<Int((seconds / step).rounded())).map { index in
            meter.update(rms: powf(10, speechDB(at: Double(index) * step, peak: peak) / 20),
                         duration: step)
        }
    }

    func testQuietAndLoudMicrophonesHaveComparableSpeechAnimation() {
        var quiet = AudioVisualLevel()
        var loud = AudioVisualLevel()
        let quietLevels = phrase(&quiet, peak: -48)
        let loudLevels = phrase(&loud, peak: -18)
        let settledQuiet = Array(quietLevels.suffix(200))
        let settledLoud = Array(loudLevels.suffix(200))
        XCTAssertGreaterThan(settledQuiet.max()!, 0.75)
        XCTAssertLessThan(settledQuiet.min()!, 0.1)
        for (quiet, loud) in zip(settledQuiet, settledLoud) {
            XCTAssertEqual(quiet, loud, accuracy: 0.08)
        }
    }

    func testQuietSpeechRespondsDuringFirstWord() {
        var meter = AudioVisualLevel()
        let levels = phrase(&meter, peak: -50, seconds: 1)
        XCTAssertGreaterThan(levels.max()!, 0.7)
    }

    func testGainChangeRecalibratesWithoutRestarting() {
        var meter = AudioVisualLevel()
        phrase(&meter, peak: -18)
        let quietLevels = phrase(&meter, peak: -48, seconds: 12)
        var quietStart = AudioVisualLevel()
        let expected = phrase(&quietStart, peak: -48, seconds: 12)
        for (actual, expected) in zip(quietLevels.suffix(100), expected.suffix(100)) {
            XCTAssertEqual(actual, expected, accuracy: 0.02)
        }
    }

    func testSilenceAndSteadyRoomNoiseDoNotGrowDuringPause() {
        var meter = AudioVisualLevel()
        phrase(&meter, peak: -40)
        for _ in 0..<500 { _ = meter.update(rms: powf(10, -65 / 20), duration: 0.02) }
        XCTAssertEqual(meter.value, 0)
        let resumed = phrase(&meter, peak: -40, seconds: 2)
        XCTAssertGreaterThan(resumed.max()!, 0.7)
        for _ in 0..<100 { _ = meter.update(rms: 0, duration: 0.02) }
        XCTAssertEqual(meter.value, 0)
    }

    func testSteadyNoiseAtStartupSettlesWithoutFullHeightAnimation() {
        var meter = AudioVisualLevel()
        for _ in 0..<200 { _ = meter.update(rms: powf(10, -50 / 20), duration: 0.02) }
        XCTAssertEqual(meter.value, 0)
    }

    func testSingleLoudClickDoesNotFlattenFollowingQuietSpeech() {
        var meter = AudioVisualLevel()
        phrase(&meter, peak: -48)
        _ = meter.update(rms: 1, duration: 0.02)
        let levels = phrase(&meter, peak: -48, seconds: 2)
        XCTAssertGreaterThan(levels.dropFirst(25).max()!, 0.75)
    }

    func testTimingDoesNotDependOnAudioBufferSize() {
        var smallBuffers = AudioVisualLevel()
        var largeBuffers = AudioVisualLevel()
        for index in 0..<400 {
            let rms = powf(10, speechDB(at: Double(index) * 0.02, peak: -45) / 20)
            for _ in 0..<4 { _ = smallBuffers.update(rms: rms, duration: 0.005) }
            _ = largeBuffers.update(rms: rms, duration: 0.02)
            if index > 100 {
                XCTAssertEqual(smallBuffers.value, largeBuffers.value, accuracy: 0.04)
            }
        }
    }

    func testInvalidAndExtremeInputRemainBounded() {
        var meter = AudioVisualLevel()
        for rms: Float in [.nan, .infinity, -.infinity, -1, 0, 0.00001, 1, 100] {
            let result = meter.update(rms: rms, duration: 0.02)
            XCTAssertTrue(result.isFinite)
            XCTAssertGreaterThanOrEqual(result, 0)
            XCTAssertLessThanOrEqual(result, 1)
        }
        let value = meter.value
        for duration in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertEqual(meter.update(rms: 1, duration: duration), value)
        }
    }
}
