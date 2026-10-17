import XCTest

final class AudioInputMeterTests: XCTestCase {
    private func samples(_ amplitude: Int16, count: Int = 320) -> [Int16] {
        (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    func testMutedInputWarnsAfterTenSecondsAndRecoversOnQuietSpeech() {
        var meter = AudioInputMeter()
        for _ in 0..<499 {
            XCTAssertFalse(meter.update(samples: samples(0), sampleRate: 16_000)!.showSilenceWarning)
        }
        XCTAssertTrue(meter.update(samples: samples(0), sampleRate: 16_000)!.showSilenceWarning)
        // ~-60 dBFS: much quieter than the old display's -35 dB floor.
        XCTAssertFalse(meter.update(samples: samples(33), sampleRate: 16_000)!.showSilenceWarning)
        for _ in 0..<499 {
            XCTAssertFalse(meter.update(samples: samples(0), sampleRate: 16_000)!.showSilenceWarning)
        }
        XCTAssertTrue(meter.update(samples: samples(0), sampleRate: 16_000)!.showSilenceWarning)
    }

    func testQuietWordsBetweenOneSecondTimerTicksNeverWarn() {
        var meter = AudioInputMeter()
        for index in 0..<1500 {
            let speaking = (10..<20).contains(index % 50)
            let reading = meter.update(samples: samples(speaking ? 58 : 0), sampleRate: 16_000)!
            XCTAssertFalse(reading.showSilenceWarning)
        }
    }

    func testWarningTimingFollowsRecordedDurationAtDifferentSampleRates() {
        for (rate, frames) in [(16_000.0, 160), (44_100.0, 882), (48_000.0, 2400)] {
            var meter = AudioInputMeter()
            let buffers = Int((10 * rate / Double(frames)).rounded())
            for _ in 0..<(buffers - 1) {
                XCTAssertFalse(meter.update(samples: samples(0, count: frames), sampleRate: rate)!.showSilenceWarning)
            }
            XCTAssertTrue(meter.update(samples: samples(0, count: frames), sampleRate: rate)!.showSilenceWarning)
        }
    }

    func testQuantizationNoiseDoesNotHideMutedInput() {
        var meter = AudioInputMeter()
        var reading: AudioMeterReading?
        for _ in 0..<500 { reading = meter.update(samples: samples(1), sampleRate: 16_000) }
        XCTAssertTrue(reading!.showSilenceWarning)
        XCTAssertEqual(reading!.level, 0)
    }

    func testShortPeakCountsEvenWhenBufferRMSIsTiny() {
        var meter = AudioInputMeter()
        for _ in 0..<100 { _ = meter.update(samples: samples(0, count: 4800), sampleRate: 48_000) }
        var buffer = samples(0, count: 4800)
        buffer[2400] = 20
        XCTAssertFalse(meter.update(samples: buffer, sampleRate: 48_000)!.showSilenceWarning)
    }

    func testNewRecordingStartsWithFreshCalibrationAndWarning() {
        var meter = AudioInputMeter()
        for _ in 0..<500 { _ = meter.update(samples: samples(0), sampleRate: 16_000) }
        meter = AudioInputMeter()
        let reading = meter.update(samples: samples(0), sampleRate: 16_000)!
        XCTAssertFalse(reading.showSilenceWarning)
        XCTAssertEqual(reading.level, 0)
    }

    func testInvalidBuffersAreIgnoredAndFullScalePCMIsSafe() {
        var meter = AudioInputMeter()
        XCTAssertNil(meter.update(samples: [], sampleRate: 16_000))
        for rate in [Double.nan, .infinity, 0, -1] {
            XCTAssertNil(meter.update(samples: [1], sampleRate: rate))
        }
        let reading = meter.update(samples: [.min, .max], sampleRate: 16_000)!
        XCTAssertFalse(reading.showSilenceWarning)
        XCTAssertTrue(reading.level.isFinite)
    }
}
