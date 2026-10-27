import XCTest

final class DeviceBatteryTests: XCTestCase {
    func testPowerCharacteristicCarriesVoltageChargingAndPercent() {
        let b = DeviceBattery.updated(nil, uuid: DeviceBattery.power, value: Data([1, 3, 0x68, 0x10, 87]))
        XCTAssertEqual(b, DeviceBattery(percent: 87, millivolts: 4200, charging: true, usbPower: true))
        XCTAssertEqual(b?.label, "87% · charging")
    }

    func testLevelUpdateKeepsPowerDetailsAndLowOnlyCountsOnBattery() {
        var b = DeviceBattery.updated(nil, uuid: DeviceBattery.power, value: Data([1, 0, 0x7C, 0x0E, 30]))
        b = DeviceBattery.updated(b, uuid: DeviceBattery.level, value: Data([12]))
        XCTAssertEqual(b?.percent, 12); XCTAssertEqual(b?.millivolts, 3708)
        XCTAssertTrue(b!.isLow)
        b?.usbPower = true
        XCTAssertFalse(b!.isLow)
    }

    func testUnknownVersionIsIgnored() {
        XCTAssertNil(DeviceBattery.updated(nil, uuid: DeviceBattery.power, value: Data([2, 0, 0, 0, 50])))
    }

    func testPillHintStartsBeforeLowAndNeverOnUSB() {
        var b = DeviceBattery(percent: 21)
        XCTAssertFalse(b.showsPillHint)
        b.percent = 20
        XCTAssertTrue(b.showsPillHint); XCTAssertFalse(b.isLow)
        b.usbPower = true
        XCTAssertFalse(b.showsPillHint)
    }
}
