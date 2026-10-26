import XCTest

final class BluetoothCallMonitorTests: XCTestCase {
    func testFailureKeepsRawReasonWhenBluetoothIsQuiet() {
        let reason = "Skull audio buffer overflowed; the partial recording was kept"
        XCTAssertEqual(BluetoothCallMonitor.failureMessage(reason, busy: nil), reason)
    }

    func testFailureDuringACallNamesTheHeadsetAndTheFix() {
        let busy = BluetoothCallMonitor.BusyAudio(device: "AirPods Max", call: true)
        let message = BluetoothCallMonitor.failureMessage("Skull audio buffer overflowed", busy: busy)
        XCTAssertTrue(message.contains("AirPods Max is on a call"))
        XCTAssertTrue(message.contains("USB cable"))
        XCTAssertTrue(message.contains("end the call"))
        XCTAssertFalse(message.contains("overflowed"))
    }

    func testFailureDuringMusicSaysToPauseIt() {
        let busy = BluetoothCallMonitor.BusyAudio(device: "AirPods Max", call: false)
        let message = BluetoothCallMonitor.failureMessage("Skull audio buffer overflowed", busy: busy)
        XCTAssertTrue(message.contains("AirPods Max is playing audio"))
        XCTAssertTrue(message.contains("pause the audio"))
        XCTAssertFalse(message.contains("overflowed"))
    }
}
