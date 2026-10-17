import XCTest

// Wired skull / receiver and eye tuning: hardware-lab builds only.
#if YORICK_HARDWARE_LAB

final class YorickEyeSettingsTests: XCTestCase {
    func testWirelessDeviceDiscoveryIsExact() {
        XCTAssertTrue(YorickEyeProtocol.isMicrophoneName("Yorick Wireless Microphone"))
        XCTAssertTrue(YorickEyeProtocol.isControlProduct("Yorick Wireless Microphone"))
        XCTAssertTrue(YorickEyeProtocol.isControlProduct("Yorick Desk Microphone"))
        XCTAssertFalse(YorickEyeProtocol.isMicrophoneName("Wireless Microphone"))
        XCTAssertFalse(YorickEyeProtocol.isControlProduct("XIAO nRF52840"))
        XCTAssertFalse(YorickEyeProtocol.isMicrophoneName("Yorick Wireless Microphone (unplugged)"))
    }
    func testCircularSettingsRoundTrip() {
        var s = YorickEyeSettings(); s.style = .circular
        XCTAssertEqual(s.style.title, "Circular EQ")
        XCTAssertEqual(s.command(sequence: 8), "YORICK SET 8 circular 70 85 80\n")
        let data = try! JSONEncoder().encode(s)
        XCTAssertEqual(try! JSONDecoder().decode(YorickEyeSettings.self, from: data), s)
    }
    func testEqualizerSettingsRoundTrip() {
        var s = YorickEyeSettings(); s.style = .equalizer
        XCTAssertEqual(s.command(sequence: 7), "YORICK SET 7 equalizer 70 85 80\n")
        let data = try! JSONEncoder().encode(s)
        XCTAssertEqual(try! JSONDecoder().decode(YorickEyeSettings.self, from: data), s)
    }
    func testMalformedPreferencesFallBack() {
        let defaults = UserDefaults(suiteName: "YorickEyeTests.\(UUID())")!
        defaults.set(Data("broken".utf8), forKey: YorickEyeSettings.defaultsKey)
        XCTAssertEqual(YorickEyeSettings.load(from: defaults), YorickEyeSettings())
        defaults.removeObject(forKey: YorickEyeSettings.defaultsKey)
    }
    func testSettingsRoundTripAndBounds() {
        let defaults = UserDefaults(suiteName: "YorickEyeTests.\(UUID())")!
        var s = YorickEyeSettings(); s.style = .wisp; s.size = -3; s.brightness = 999; s.motion = -8
        s.save(to: defaults)
        let result = YorickEyeSettings.load(from: defaults)
        XCTAssertEqual(result.style, .wisp); XCTAssertEqual(result.size, 60)
        XCTAssertEqual(result.style.title, "Flame") // existing saved Wisp becomes Flame
        XCTAssertEqual(result.brightness, 100); XCTAssertEqual(result.motion, 0)
        XCTAssertEqual(result.command(sequence: 17), "YORICK SET 17 wisp 100 60 0\n")
        defaults.removeObject(forKey: YorickEyeSettings.defaultsKey)
    }
    func testAudioResponseDoesNotGenerateInvalidCommands() {
        var s = YorickEyeSettings(); s.sensitivity = 200
        XCTAssertEqual(s.level(.nan), 0); XCTAssertEqual(s.level(.infinity), 0)
        XCTAssertEqual(s.level(-1), 0); XCTAssertEqual(s.level(0.75), 100)
        s.reactive = false; XCTAssertEqual(s.level(1), 0)
    }
    func testHandshakeCannotBeConfusedWithLegacyDiagnostics() {
        XCTAssertNil(YorickEyeProtocol.acknowledgedSequence("YORICK_USB_MIC_V1 uptime_ms=3"))
        XCTAssertNil(YorickEyeProtocol.acknowledgedSequence("YORICK OK 2 garbage"))
        XCTAssertEqual(YorickEyeProtocol.acknowledgedSequence("YORICK OK 42"), 42)
        XCTAssertFalse(YorickEyeProtocol.isMicrophoneName("MacBook Microphone"))
        XCTAssertFalse(YorickEyeProtocol.isMicrophoneName("Yorick Microphone (unplugged)"))
        XCTAssertTrue(YorickEyeProtocol.isMicrophoneName("Yorick Microphone"))
    }
}
#endif
