import XCTest

final class YorickDeviceKindTests: XCTestCase {
    func testUSBProductNamesMapToTheirDevice() {
        XCTAssertEqual(YorickDeviceKind(usbProductName: "Yorick Pocket BLE"), .pocket)
        XCTAssertEqual(YorickDeviceKind(usbProductName: "Yorick Skull Mini USB"), .mini)
        XCTAssertEqual(YorickDeviceKind(usbProductName: "Yorick Desk Microphone"), .skull)
    }

    func testOtherUSBDevicesAreIgnored() {
        XCTAssertNil(YorickDeviceKind(usbProductName: "USB Audio Device"))
        XCTAssertNil(YorickDeviceKind(usbProductName: "Blue Yeti"))
        XCTAssertNil(YorickDeviceKind(usbProductName: "My Yorick Pocket"))
    }

    func testEachKindHasItsOwnServiceAndInput() {
        XCTAssertEqual(Set(YorickDeviceKind.allCases.map(\.service)).count, 3)
        XCTAssertEqual(YorickDeviceKind.mini.deviceUID, SkullMiniBluetoothProtocol.deviceUID)
        XCTAssertEqual(YorickDeviceKind.pocket.deviceUID, PocketBluetoothProtocol.deviceUID)
    }
}
