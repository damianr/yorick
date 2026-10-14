import XCTest

@MainActor
private final class FakeEyeLink: YorickEyeLink {
    var isLinkReady = true
    var sent: [String] = []
    var incoming: [String] = []
    func sendEyeLine(_ line: String) { sent.append(line) }
    func takeEyeLines() -> [String] { defer { incoming.removeAll() }; return incoming }
}

final class SkullBluetoothProtocolTests: XCTestCase {
    func testRepliesAndLines() {
        XCTAssertEqual(SkullBluetoothProtocol.parse("YORICK END 7 16000"), .ended(session: 7, samples: 16000))
        XCTAssertEqual(SkullBluetoothProtocol.parse("YORICK OVERFLOW 7 0"), .overflowed(session: 7))
        XCTAssertEqual(SkullBluetoothProtocol.parse("YORICK REFUSED 9"), .refused(session: 9))
        XCTAssertEqual(SkullBluetoothProtocol.parse("YORICK EYES 1"), .eye("YORICK EYES 1"))
        XCTAssertNil(SkullBluetoothProtocol.parse("YORICK END x 1"))
        XCTAssertNil(SkullBluetoothProtocol.parse("HELLO"))
        XCTAssertEqual(SkullBluetoothProtocol.encode("YORICK HELLO 1\n"), Data("YORICK HELLO 1".utf8))
        XCTAssertNil(SkullBluetoothProtocol.encode(String(repeating: "x", count: 89)))
        XCTAssertNil(SkullBluetoothProtocol.encode("YORICK\u{7}"))
        XCTAssertEqual(SkullBluetoothProtocol.listen(42), "YORICK LISTEN 42")
        XCTAssertTrue(YorickEyeProtocol.isMicrophoneName(SkullBluetoothProtocol.deviceName))
    }

    /// Selecting the skull's Bluetooth input runs the eye protocol over the
    /// link, and voice state reaches the eyes only while it is the active mic.
    @MainActor func testEyesOverBluetoothOnlyReactWhenSkullIsRecording() {
        let defaults = UserDefaults(suiteName: "SkullBLETests.\(UUID())")!
        let mic = YorickMicController(monitor: false, defaults: defaults, discover: { (0, []) })
        let link = FakeEyeLink()
        var selected = true
        mic.bluetoothLink = link; mic.bluetoothSelected = { selected }
        mic.tick()
        XCTAssertTrue(mic.attached); XCTAssertFalse(mic.controlsReady)
        XCTAssertTrue(link.sent.contains("YORICK HELLO 1"))
        link.incoming = ["YORICK EYES 1"]; mic.tick()
        XCTAssertTrue(mic.controlsReady); XCTAssertTrue(mic.showEyeControls)
        let set = link.sent.last { $0.hasPrefix("YORICK SET") }!
        link.incoming = ["YORICK OK \(set.split(separator: " ")[2])"]; mic.tick()
        XCTAssertTrue(mic.applied)
        XCTAssertEqual(link.sent.last, "YORICK STATE 0 0")
        // Recording through another mic never animates the skull.
        mic.recording = true; mic.recordingMicName = "MacBook Pro Microphone"; mic.audioLevel = 0.9; mic.tick()
        XCTAssertEqual(link.sent.last, "YORICK STATE 0 0")
        mic.recordingMicName = SkullBluetoothProtocol.deviceName; mic.tick()
        XCTAssertTrue(link.sent.last!.hasPrefix("YORICK STATE 1 "))
        // A powered-off skull hides the controls; switching inputs stops the stream.
        link.isLinkReady = false; mic.tick()
        XCTAssertFalse(mic.attached); XCTAssertFalse(mic.showEyeControls)
        link.isLinkReady = true; selected = false; link.sent.removeAll(); mic.tick()
        XCTAssertFalse(mic.attached); XCTAssertTrue(link.sent.isEmpty)
    }
}
