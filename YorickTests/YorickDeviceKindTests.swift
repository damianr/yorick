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

    func testMG24USBBridgeStartsASearch() {
        XCTAssertTrue(YorickDeviceKind.isSkullUSBBridge(vendor: 0x2886, product: 0x0062, name: "CMSIS-DAP"))
        XCTAssertTrue(YorickDeviceKind.isSkullUSBBridge(vendor: 0x2886, product: 0x1234, name: "XIAO MG24"))
    }

    func testOtherBoardsDontStartASearch() {
        XCTAssertFalse(YorickDeviceKind.isSkullUSBBridge(vendor: 0x2886, product: 0x8045, name: "XIAO nRF52840 Sense"))
        XCTAssertFalse(YorickDeviceKind.isSkullUSBBridge(vendor: 0x046D, product: 0x0062, name: "MG24"))
        XCTAssertFalse(YorickDeviceKind.isSkullUSBBridge(vendor: nil, product: nil, name: nil))
    }
}
