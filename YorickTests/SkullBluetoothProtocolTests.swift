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
    func testButtonsIgnoreReconnectAndDuplicateStates() {
        var state = SkullButtonState()
        XCTAssertNil(state.accept(down: false, returns: 4).talk)
        let press = state.accept(down: true, returns: 4)
        XCTAssertEqual(press.talk, true)
        XCTAssertEqual(press.returns, 0)
        XCTAssertNil(state.accept(down: true, returns: 4).talk)
        let release = state.accept(down: false, returns: 7)
        XCTAssertEqual(release.talk, false)
        XCTAssertEqual(release.returns, 3)
        XCTAssertEqual(state.accept(down: false, returns: 7).returns, 0)
        XCTAssertEqual(state.accept(down: false, returns: 0).returns, 0)
        state = SkullButtonState()
        let reconnect = state.accept(down: true, returns: 99)
        XCTAssertNil(reconnect.talk)
        XCTAssertEqual(reconnect.returns, 0)
        XCTAssertEqual(state.accept(down: false, returns: 99).talk, false)
    }
    func testButtonWireValidation() {
        XCTAssertEqual(SkullBluetoothProtocol.parse("YORICK BUTTON 1 1 3"), .buttons(down: true, returns: 3))
        for line in ["YORICK BUTTON 1 2 3", "YORICK BUTTON 2 1 3", "YORICK BUTTON 1 1 -1", "YORICK BUTTON 1 1", "YORICK BUTTON 1 1 0 extra"] {
            XCTAssertNil(SkullBluetoothProtocol.parse(line))
        }
    }
    func testMiniButtonWireValidation() {
        XCTAssertEqual(SkullMiniBluetoothProtocol.parse("YORICK BUTTON 1 1 3"), .buttons(down: true, returns: 3))
        for line in ["YORICK BUTTON 1 2 3", "YORICK BUTTON 2 1 3", "YORICK BUTTON 1 1 -1", "YORICK BUTTON 1 1", "YORICK BUTTON 1 1 0 extra"] {
            XCTAssertNil(SkullMiniBluetoothProtocol.parse(line))
        }
    }
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
        #if YORICK_HARDWARE_LAB
        XCTAssertTrue(YorickEyeProtocol.isMicrophoneName(SkullBluetoothProtocol.deviceName))
        #endif
    }

    /// Selecting the skull's Bluetooth input runs the eye protocol over the
    /// link, and voice state reaches the eyes only while it is the active mic.
    @MainActor func testEyesOverBluetoothOnlyReactWhenSkullIsRecording() {
        #if YORICK_HARDWARE_LAB
        let defaults = UserDefaults(suiteName: "SkullBLETests.\(UUID())")!
        let mic = YorickMicController(monitor: false, defaults: defaults, discover: { (0, []) })
        #else
        // Public builds: Bluetooth only, default eyes.
        let mic = YorickMicController(monitor: false)
        #endif
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

final class BluetoothUnitsTests: XCTestCase {
    private let a = UUID(uuidString: "7D80318B-9BE2-677C-E957-5F7160C9BBED")!
    private let b = UUID(uuidString: "93418D2C-5DB9-5321-D5A9-D65EE2E1D494")!

    func testEachSkullIsItsOwnUnit() {
        var units = BluetoothUnits()
        units.saw(a, name: "Yorick Skull MG24")
        units.saw(b, name: "Yorick Skull")
        units.saw(a, name: nil)
        XCTAssertEqual(units.all.map(\.name), ["Yorick Skull", "Yorick Skull MG24"])
    }

    func testSameNamesGetASuffix() {
        var units = BluetoothUnits()
        units.saw(a, name: "Yorick Skull"); units.saw(b, name: "Yorick Skull")
        XCTAssertEqual(Set(units.all.map(units.label)), ["Yorick Skull · 7D80", "Yorick Skull · 9341"])
    }

    func testSwitchedOffSkullsDropButTheLinkedOneStays() {
        var units = BluetoothUnits()
        let then = Date()
        units.saw(a, name: "Yorick Skull MG24", at: then); units.saw(b, name: "Yorick Skull", at: then)
        units.expire(keeping: b, at: then.addingTimeInterval(BluetoothUnits.forgetAfter + 1))
        XCTAssertEqual(units.all.map(\.id), [b])
    }
}
