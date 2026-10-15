import Foundation
@preconcurrency import CoreBluetooth
import os

/// The skull over Bluetooth LE: audio while Yorick is listening, and the same
/// eye-control lines the USB/receiver serial path carries. Unlike the pocket,
/// the Mac's hotkey starts and stops each session.
@MainActor
@Observable
final class SkullBluetoothController: NSObject, YorickEyeLink {
    private(set) var status = "Not connected"
    private(set) var connected = false
    private(set) var battery: DeviceBattery? { didSet { if battery != oldValue { onBatteryChanged?(battery) } } }
    var onBatteryChanged: ((DeviceBattery?) -> Void)?
    private(set) var receivedFrames = 0
    private(set) var missingSamples = 0
    var onSamples: (([Int16]) -> Void)?
    /// The session's audio is complete (or abandoned); safe to finalize the WAV.
    var onStop: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var audio: CBCharacteristic?
    private var replies: CBCharacteristic?
    private var control: CBCharacteristic?
    private var timer: Timer?
    private var wanted = false
    private var allowNew = false
    private var session = UInt32.random(in: 1...0x7FFF_FFFF)
    private var assembler: PocketBluetoothProtocol.Assembler?
    private var stopTarget: UInt32?
    private var stopDeadline: Date?
    private var lastAudio = Date.distantPast
    private var reconnectAfter = Date.distantPast
    private var batteryCharacteristics: [CBCharacteristic] = []
    private var batteryReadAt = Date.distantPast
    private var eyeLines: [String] = []
    private let log = Logger(subsystem: "com.heyyorick.Yorick", category: "skullBLE")
    static let savedPeer = "skullBluetoothPeer"

    static var isPaired: Bool { UserDefaults.standard.string(forKey: savedPeer) != nil }

    func start(pairNew: Bool = false) {
        wanted = true; allowNew = allowNew || pairNew
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common); timer = t
        } else { connectIfPossible() }
    }
    func restoreIfConfigured() { if Self.isPaired { start() } }

    // MARK: Listening sessions

    var listening: Bool { assembler != nil }

    /// Begin streaming; the skull includes ~100 ms of audio from before this call.
    @discardableResult
    func listen() -> Bool {
        guard connected, assembler == nil else { return false }
        session = session &+ 1 == 0 ? 1 : session &+ 1
        assembler = .init(session: session); stopTarget = nil; stopDeadline = nil
        receivedFrames = 0; missingSamples = 0; lastAudio = Date()
        write(SkullBluetoothProtocol.listen(session), reliable: true)
        log.notice("listen session=\(self.session)")
        return true
    }

    /// Ask the skull to flush its tail; onStop fires once the audio is complete.
    func stopListening() {
        guard assembler != nil, stopDeadline == nil else { return }
        write(SkullBluetoothProtocol.stopListening, reliable: true)
        stopDeadline = Date().addingTimeInterval(0.8)
    }

    private func finish() {
        guard let a = assembler else { return }
        log.notice("session complete frames=\(a.frames) missingSamples=\(a.missingSamples) samples=\(a.expectedOffset)")
        assembler = nil; stopTarget = nil; stopDeadline = nil
        onStop?()
    }
    private func fail(_ reason: String) {
        log.error("\(reason, privacy: .public)")
        let had = assembler != nil
        assembler = nil; stopTarget = nil; stopDeadline = nil
        if had { onStop?() }
        onFailure?(reason)
    }

    // MARK: YorickEyeLink

    var isLinkReady: Bool { connected }
    func sendEyeLine(_ line: String) {
        // STATE is a 10 Hz latest-value stream; everything else must arrive.
        write(line, reliable: !line.hasPrefix("YORICK STATE "))
    }
    func takeEyeLines() -> [String] { defer { eyeLines.removeAll() }; return eyeLines }

    private func write(_ line: String, reliable: Bool) {
        guard let p = peripheral, p.state == .connected, let c = control,
              let data = SkullBluetoothProtocol.encode(line) else { return }
        if reliable { p.writeValue(data, for: c, type: .withResponse) }
        else if p.canSendWriteWithoutResponse { p.writeValue(data, for: c, type: .withoutResponse) }
    }

    // MARK: Link

    private func connectIfPossible() {
        guard wanted, central?.state == .poweredOn, peripheral == nil else { return }
        if let value = UserDefaults.standard.string(forKey: Self.savedPeer), let id = UUID(uuidString: value),
           let peer = central?.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = peer; peer.delegate = self; status = "Connecting…"
            central?.connect(peer); return
        }
        guard allowNew else { status = "Skull unavailable"; return }
        status = "Looking for the skull…"
        central?.scanForPeripherals(withServices: [CBUUID(string: SkullBluetoothProtocol.service)])
    }
    private func tick() {
        // Notifications carry changes; a slow poll keeps voltage fresh and covers older firmware.
        if connected, !batteryCharacteristics.isEmpty, Date().timeIntervalSince(batteryReadAt) > 60 {
            batteryReadAt = Date(); batteryCharacteristics.forEach { peripheral?.readValue(for: $0) }
        }
        if wanted, peripheral == nil, Date() >= reconnectAfter {
            reconnectAfter = Date().addingTimeInterval(3); connectIfPossible()
        }
        if let deadline = stopDeadline, Date() >= deadline {
            if let a = assembler, let target = stopTarget, a.expectedOffset < target {
                missingSamples += Int(target - a.expectedOffset)
                log.error("tail missing samples=\(target - a.expectedOffset)")
            }
            finish()
        } else if assembler != nil, stopDeadline == nil, Date().timeIntervalSince(lastAudio) > 2 {
            write(SkullBluetoothProtocol.stopListening, reliable: true)
            fail("Skull audio stopped arriving; the partial recording was kept")
        }
    }
    private func handleReply(_ data: Data) {
        guard let line = String(data: data, encoding: .ascii), let reply = SkullBluetoothProtocol.parse(line) else { return }
        switch reply {
        case .eye(let text):
            if eyeLines.count < 16 { eyeLines.append(text) }
        case .ended(let s, let samples):
            guard let a = assembler, a.session == s else { return }
            stopTarget = samples
            if a.expectedOffset >= samples { finish() }
        case .overflowed(let s):
            if assembler?.session == s { fail("Skull audio buffer overflowed; the partial recording was kept") }
        case .refused(let s):
            if assembler?.session == s { fail("The skull wasn't ready to listen. Try again in a moment.") }
        }
    }
    private func handleAudio(_ data: Data) {
        guard let f = PocketBluetoothProtocol.Frame(data), var a = assembler, let samples = a.accept(f) else { return }
        assembler = a; receivedFrames = a.frames; missingSamples = a.missingSamples
        lastAudio = Date(); onSamples?(samples)
        if let target = stopTarget, a.expectedOffset >= target { finish() }
    }
}

extension SkullBluetoothController: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connectIfPossible()
        case .unauthorized: status = "Allow Yorick to use Bluetooth in System Settings"
        case .poweredOff: status = "Bluetooth is off"
        default: status = "Bluetooth unavailable"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil, allowNew else { return }
        self.peripheral = peripheral; peripheral.delegate = self; central.stopScan()
        status = "Connecting…"; central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Preparing encrypted connection…"
        peripheral.discoverServices([CBUUID(string: SkullBluetoothProtocol.service), DeviceBattery.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil; reconnectAfter = Date().addingTimeInterval(3)
        status = "Connection failed — retrying…"
        log.error("connection failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let was = connected
        connected = false; audio = nil; replies = nil; control = nil; eyeLines.removeAll()
        battery = nil; batteryCharacteristics.removeAll()
        if was { onConnectionChanged?(false) }
        if assembler != nil { fail("The skull disconnected; the partial recording was kept") }
        self.peripheral = nil; status = "Reconnecting…"
        if wanted { connectIfPossible() }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let bas = peripheral.services?.first(where: { $0.uuid == DeviceBattery.service }) {
            peripheral.discoverCharacteristics([DeviceBattery.level], for: bas)
        }
        guard error == nil, let s = peripheral.services?.first(where: { $0.uuid == CBUUID(string: SkullBluetoothProtocol.service) }) else {
            status = "Skull Bluetooth service unavailable. Update the skull firmware."; return
        }
        peripheral.discoverCharacteristics(nil, for: s)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if service.uuid == DeviceBattery.service, error != nil { return }
        guard error == nil else { status = "Could not prepare the skull"; return }
        let batteryUUIDs = [DeviceBattery.level, DeviceBattery.power]
        for c in service.characteristics ?? [] where batteryUUIDs.contains(c.uuid) {
            batteryCharacteristics.append(c); peripheral.readValue(for: c)
            if c.properties.contains(.notify) { peripheral.setNotifyValue(true, for: c) }
        }
        if service.uuid == DeviceBattery.service { return }
        for c in service.characteristics ?? [] {
            if c.uuid == CBUUID(string: SkullBluetoothProtocol.audio) { audio = c }
            if c.uuid == CBUUID(string: SkullBluetoothProtocol.replies) { replies = c }
            if c.uuid == CBUUID(string: SkullBluetoothProtocol.control) { control = c }
        }
        guard let audio, let replies, control != nil else { return }
        peripheral.setNotifyValue(true, for: audio); peripheral.setNotifyValue(true, for: replies)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if batteryCharacteristics.contains(characteristic) { return }
        guard error == nil else { status = "Bluetooth pairing or subscription failed"; return }
        if audio?.isNotifying == true, replies?.isNotifying == true, !connected {
            connected = true; status = "Connected"; allowNew = false
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeer)
            onConnectionChanged?(true)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        if batteryCharacteristics.contains(characteristic) {
            battery = DeviceBattery.updated(battery, uuid: characteristic.uuid, value: value); return
        }
        if characteristic.uuid == CBUUID(string: SkullBluetoothProtocol.replies) { handleReply(value) }
        else if characteristic.uuid == CBUUID(string: SkullBluetoothProtocol.audio) { handleAudio(value) }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log.error("control write failed: \(error.localizedDescription, privacy: .public)") }
    }
}
