import Foundation

/// Wire protocol shared with yorick-skull firmware/skull-ble. Audio frames use
/// the pocket microphone's IMA framing; control and replies are the skull's
/// existing eye text lines plus LISTEN/END for Mac-driven sessions.
enum SkullBluetoothProtocol {
    static let deviceUID = "yorick-skull-ble"
    static let deviceName = "Yorick Skull Bluetooth"
    static let service = "61C57A10-4CC3-4B68-ACD7-14C4A67E1300"
    static let audio = "61C57A10-4CC3-4B68-ACD7-14C4A67E1301"
    static let replies = "61C57A10-4CC3-4B68-ACD7-14C4A67E1302"
    static let control = "61C57A10-4CC3-4B68-ACD7-14C4A67E1303"
    static let maxLine = 88

    static func listen(_ session: UInt32) -> String { "YORICK LISTEN \(session)" }
    static let stopListening = "YORICK LISTEN 0"

    enum Reply: Equatable {
        /// The session's audio is complete at `samples` samples.
        case ended(session: UInt32, samples: UInt32)
        case overflowed(session: UInt32)
        case refused(session: UInt32)
        /// Eye protocol lines (EYES/OK), handled by YorickMicController.
        case eye(String)
        case buttons(down: Bool, returns: UInt32)
    }

    static func parse(_ line: String) -> Reply? {
        let parts = line.split(separator: " ")
        guard parts.first == "YORICK", parts.count >= 2 else { return nil }
        switch parts[1] {
        case "BUTTON":
            guard parts.count == 5, parts[2] == "1", ["0", "1"].contains(parts[3]), let n = UInt32(parts[4]) else { return nil }
            return .buttons(down: parts[3] == "1", returns: n)
        case "END":
            guard parts.count == 4, let s = UInt32(parts[2]), let n = UInt32(parts[3]) else { return nil }
            return .ended(session: s, samples: n)
        case "OVERFLOW":
            guard parts.count == 4, let s = UInt32(parts[2]) else { return nil }
            return .overflowed(session: s)
        case "REFUSED":
            guard parts.count == 3, let s = UInt32(parts[2]) else { return nil }
            return .refused(session: s)
        default:
            return .eye(line)
        }
    }

    /// One ATT write per line: printable ASCII, no newline, at most 88 bytes.
    static func encode(_ line: String) -> Data? {
        let trimmed = line.trimmingCharacters(in: .newlines)
        let bytes = Array(trimmed.utf8)
        guard !bytes.isEmpty, bytes.count <= maxLine, bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return Data(bytes)
    }
}

/// First state after reconnect establishes a baseline and never replays actions.
struct SkullButtonState {
    private var down: Bool?
    private var returns: UInt32 = 0
    mutating func accept(down next: Bool, returns count: UInt32) -> (talk: Bool?, returns: Int) {
        defer { down = next; returns = count }
        guard let down else { return (nil, 0) }
        let delta = count &- returns
        return (down == next ? nil : next, delta <= 8 ? Int(delta) : 0)
    }
}

/// Every skull of one model that's switched on near this Mac, each its own
/// device. Same-model skulls share one GATT service; CoreBluetooth's
/// identifier for each (stable on this Mac) tells them apart, so the firmware
/// needs no serial number.
struct BluetoothUnits: Equatable {
    struct Unit: Identifiable, Equatable {
        let id: UUID
        var name: String
        var seenAt: Date
    }
    private(set) var all: [Unit] = []
    /// A skull advertises every 100 ms while on; a rescan every 10 s refreshes it.
    static let forgetAfter: TimeInterval = 25

    mutating func saw(_ id: UUID, name: String?, at now: Date = Date()) {
        if let i = all.firstIndex(where: { $0.id == id }) {
            all[i].seenAt = now
            if let name, !name.isEmpty { all[i].name = name }
        } else {
            all.append(Unit(id: id, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "Yorick Skull", seenAt: now))
            all.sort { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        }
    }

    /// A connected skull stops advertising, so the linked one is always kept.
    mutating func expire(keeping linked: UUID?, at now: Date = Date()) {
        all.removeAll { $0.id != linked && now.timeIntervalSince($0.seenAt) > Self.forgetAfter }
    }

    /// Two skulls with the same firmware name get a short suffix to tell apart.
    func label(_ unit: Unit) -> String {
        all.filter { $0.name == unit.name }.count > 1 ? "\(unit.name) · \(unit.id.uuidString.prefix(4))" : unit.name
    }
}
