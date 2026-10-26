import XCTest

final class BluetoothCallMonitorTests: XCTestCase {
    func testFailureKeepsRawReasonWithoutACall() {
        let reason = "Skull audio buffer overflowed; the partial recording was kept"
        XCTAssertEqual(BluetoothCallMonitor.failureMessage(reason, callDevice: nil), reason)
    }

    func testFailureDuringACallNamesTheHeadsetAndTheFix() {
        let message = BluetoothCallMonitor.failureMessage("Skull audio buffer overflowed", callDevice: "AirPods Max")
        XCTAssertTrue(message.contains("AirPods Max is on a Bluetooth call"))
        XCTAssertTrue(message.contains("USB cable"))
        XCTAssertFalse(message.contains("overflowed"))
    }
}
