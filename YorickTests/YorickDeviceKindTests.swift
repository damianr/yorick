import XCTest
@testable import Yorick

final class YorickDeviceKindTests: XCTestCase {
    func testMG24BridgeStartsASearch() {
        XCTAssertTrue(YorickDeviceKind.isSkullUSBBridge(vendor: 0x2886, product: 0x0062, name: "CMSIS-DAP"))
        XCTAssertTrue(YorickDeviceKind.isSkullUSBBridge(vendor: 0x2886, product: 0x1234, name: "XIAO MG24"))
    }

    func testOtherUSBDevicesDont() {
        XCTAssertFalse(YorickDeviceKind.isSkullUSBBridge(vendor: 0x2886, product: 0x0045, name: "XIAO ESP32S3"))
        XCTAssertFalse(YorickDeviceKind.isSkullUSBBridge(vendor: 0x046D, product: 0x0062, name: "MG24"))
        XCTAssertFalse(YorickDeviceKind.isSkullUSBBridge(vendor: nil, product: nil, name: nil))
    }

    func testYorickProductNames() {
        XCTAssertEqual(YorickDeviceKind(usbProductName: "Yorick Skull Mini USB"), .mini)
        XCTAssertEqual(YorickDeviceKind(usbProductName: "Yorick Pocket BLE"), .pocket)
        XCTAssertNil(YorickDeviceKind(usbProductName: "CMSIS-DAP"))
    }
}
