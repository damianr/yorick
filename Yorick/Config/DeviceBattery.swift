import Foundation
@preconcurrency import CoreBluetooth

/// A Yorick device's battery as its firmware reports it: the standard Battery
/// Service level, plus (on the Pocket) a power characteristic carrying the
/// voltage and whether it is charging.
struct DeviceBattery: Equatable {
    var percent: Int
    var millivolts: Int?
    var charging = false
    var usbPower = false

    static let service = CBUUID(string: "180F")
    static let level = CBUUID(string: "2A19")
    /// [version 1, flags (1 charging, 2 USB power), millivolts LE16, percent]
    static let power = CBUUID(string: "61C57A10-4CC3-4B68-ACD7-14C4A67E1204")
    static let lowPercent = 15

    /// Low only means something on battery; plugged in, it's on its way up.
    var isLow: Bool { percent <= Self.lowPercent && !usbPower }

    var label: String {
        if charging { return "\(percent)% · charging" }
        if usbPower { return "\(percent)% · plugged in" }
        return "\(percent)%"
    }

    var symbol: String {
        if charging || usbPower { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Fold a characteristic update into the current reading.
    static func updated(_ current: DeviceBattery?, uuid: CBUUID, value: Data) -> DeviceBattery? {
        let bytes = [UInt8](value)
        if uuid == level, let first = bytes.first {
            var b = current ?? DeviceBattery(percent: 0)
            b.percent = Int(min(first, 100)); return b
        }
        if uuid == power, bytes.count >= 5, bytes[0] == 1 {
            var b = current ?? DeviceBattery(percent: 0)
            b.charging = bytes[1] & 1 != 0; b.usbPower = bytes[1] & 2 != 0
            b.millivolts = Int(bytes[2]) | Int(bytes[3]) << 8
            b.percent = Int(min(bytes[4], 100)); return b
        }
        return current
    }
}
