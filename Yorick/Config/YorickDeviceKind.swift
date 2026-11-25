import CoreBluetooth

/// The three microphones made for Yorick.
enum YorickDeviceKind: String, CaseIterable, Codable, Sendable {
    case pocket, skull, mini

    var name: String {
        switch self {
        case .pocket: "Yorick Pocket"
        case .skull: "Yorick Skull"
        case .mini: "Yorick Skull Mini"
        }
    }

    var service: CBUUID {
        switch self {
        case .pocket: CBUUID(string: PocketBluetoothProtocol.service)
        case .skull: CBUUID(string: SkullBluetoothProtocol.service)
        case .mini: CBUUID(string: SkullMiniBluetoothProtocol.service)
        }
    }

    var deviceUID: String {
        switch self {
        case .pocket: PocketBluetoothProtocol.deviceUID
        case .skull: SkullBluetoothProtocol.deviceUID
        case .mini: SkullMiniBluetoothProtocol.deviceUID
        }
    }

    /// A Yorick device on a USB cable (charging, usually) names itself by
    /// its firmware's product string: "Yorick Pocket BLE", "Yorick Skull Mini USB".
    init?(usbProductName name: String) {
        guard name.hasPrefix("Yorick") else { return nil }
        if name.contains("Pocket") { self = .pocket }
        else if name.contains("Mini") { self = .mini }
        else { self = .skull }
    }

    /// Seeed XIAO MG24's onboard CMSIS-DAP bridge, the only USB an MG24 skull
    /// has. Any XIAO MG24 matches, so this only starts a Bluetooth search.
    static func isSkullUSBBridge(vendor: Int?, product: Int?, name: String?) -> Bool {
        guard vendor == 0x2886 else { return false }
        return product == 0x0062 || (name?.localizedCaseInsensitiveContains("MG24") ?? false)
    }
}
