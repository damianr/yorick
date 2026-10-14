import Foundation
@preconcurrency import CoreBluetooth
import os

@MainActor
@Observable
final class PocketBluetoothController: NSObject {
    private(set) var status = "Not connected"
    private(set) var connected = false
    private(set) var receivedFrames = 0
    private(set) var missingSamples = 0
    private(set) var rejectedFrames = 0
    var onStart: (() -> Bool)?
    var onSamples: (([Int16]) -> Void)?
    var onStop: (() -> Void)?
    var onReturn: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var isSelected: (() -> Bool)?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var audio: CBCharacteristic?
    private var events: CBCharacteristic?
    private var commands: CBCharacteristic?
    private var timer: Timer?
    private var wanted = false
    private var allowNew = false
    private var armed = false
    private var assembler: PocketBluetoothProtocol.Assembler?
    private var stopTarget: UInt32?
    private var stopDeadline: Date?
    private var lastAudio = Date.distantPast
    private var seen: [UInt64: Bool] = [:]
    private var seenOrder: [UInt64] = []
    private var lastHeartbeat = Date.distantPast
    private var reconnectAfter = Date.distantPast
    private let log = Logger(subsystem: "com.heyyorick.Yorick", category: "pocketBLE")
    private static let savedPeer = "pocketBluetoothPeer"

    func start(pairNew: Bool = false) {
        wanted = true; allowNew = pairNew
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common); timer = t
        } else { connectIfPossible() }
    }
    func restoreIfConfigured() {
        if UserDefaults.standard.string(forKey: Self.savedPeer) != nil { start() }
    }
    func selectionChanged() {
        if isSelected?() != true {
            send(PocketBluetoothProtocol.command(0x82)); armed = false
            if assembler != nil { fail("Pocket microphone selection changed") }
        } else if connected { arm() }
    }
    private func connectIfPossible() {
        guard wanted, central?.state == .poweredOn, peripheral == nil else { return }
        if let value = UserDefaults.standard.string(forKey: Self.savedPeer), let id = UUID(uuidString: value),
           let peer = central?.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = peer; peer.delegate = self; status = "Connecting…"
            central?.connect(peer); return
        }
        guard allowNew else { status = "Pocket microphone unavailable"; return }
        status = "Looking for pocket microphone…"
        central?.scanForPeripherals(withServices: [CBUUID(string: PocketBluetoothProtocol.service)])
    }
    private func send(_ data: Data) {
        guard let p = peripheral, p.state == .connected, let c = commands else { return }
        p.writeValue(data, for: c, type: .withResponse)
    }
    private func arm() {
        guard isSelected?() == true, audio?.isNotifying == true, events?.isNotifying == true else { return }
        send(PocketBluetoothProtocol.command(0x81)); lastHeartbeat = Date()
    }
    private func finish() {
        guard let a = assembler else { return }
        log.notice("session complete frames=\(a.frames) missingSamples=\(a.missingSamples) samples=\(a.expectedOffset)")
        assembler = nil; stopTarget = nil; stopDeadline = nil
        onStop?()
    }
    private func fail(_ reason: String) {
        log.error("\(reason, privacy: .public)")
        let hadRecording = assembler != nil
        assembler = nil; stopTarget = nil; stopDeadline = nil
        if hadRecording { onStop?() }
        onFailure?(reason)
    }
    private func tick() {
        if wanted, peripheral == nil, Date() >= reconnectAfter {
            reconnectAfter = Date().addingTimeInterval(3); connectIfPossible()
        }
        if connected, isSelected?() == true, Date().timeIntervalSince(lastHeartbeat) > 1 {
            send(PocketBluetoothProtocol.command(armed ? 0x83 : 0x81)); lastHeartbeat = Date()
        }
        if let deadline = stopDeadline, Date() >= deadline {
            if let target = stopTarget, let a = assembler, a.expectedOffset < target {
                missingSamples += Int(target-a.expectedOffset)
                onFailure?("Bluetooth audio ended with a missing tail")
            }
            finish()
        } else if assembler != nil, Date().timeIntervalSince(lastAudio) > 2 {
            send(PocketBluetoothProtocol.command(0x82)); armed = false
            fail("Bluetooth audio stopped arriving; the partial recording was kept")
        }
    }
    private func handleEvent(_ data: Data) {
        guard let e = PocketBluetoothProtocol.Event(data) else { return }
        let key = UInt64(e.boot) << 32 | UInt64(e.id)
        if let accepted = seen[key] { send(e.acknowledgment(accepted: accepted)); return }
        var accepted = true
        switch e.type {
        case 1:
            guard isSelected?() == true, assembler == nil, onStart?() == true else {
                accepted = false; break
            }
            assembler = .init(session: e.session); receivedFrames = 0; missingSamples = 0
            lastAudio = Date(); log.notice("talk start session=\(e.session)")
        case 2:
            if assembler?.session == e.session {
                stopTarget = e.endSample; stopDeadline = Date().addingTimeInterval(0.5)
                if let a = assembler, a.expectedOffset >= e.endSample { finish() }
            }
        case 3:
            if isSelected?() == true { onReturn?(); log.notice("Return event=\(e.id)") }
        case 4:
            armed = true; status = "Connected — ready"; log.notice("encrypted pocket link ready")
        case 5:
            fail("Pocket microphone buffer overflowed; the partial recording was kept")
        default: break
        }
        seen[key] = accepted; seenOrder.append(key)
        if seenOrder.count > 128 { seen.removeValue(forKey: seenOrder.removeFirst()) }
        send(e.acknowledgment(accepted: accepted))
    }
    private func handleAudio(_ data: Data) {
        guard let f = PocketBluetoothProtocol.Frame(data), var a = assembler else { rejectedFrames += 1; return }
        guard let samples = a.accept(f) else { rejectedFrames += 1; return }
        assembler = a; receivedFrames = a.frames; missingSamples = a.missingSamples
        lastAudio = Date(); onSamples?(samples)
        if a.missingSamples > 0 { status = "Connected — audio gap detected" }
        if let target = stopTarget, a.expectedOffset >= target { finish() }
    }
}

extension PocketBluetoothController: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
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
        peripheral.discoverServices([CBUUID(string: PocketBluetoothProtocol.service)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil; reconnectAfter = Date().addingTimeInterval(3)
        status = "Connection failed — retrying…"
        log.error("connection failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = false; armed = false; audio = nil; events = nil; commands = nil
        seen.removeAll(); seenOrder.removeAll(); onConnectionChanged?(false)
        if assembler != nil { fail("Pocket microphone disconnected; the partial recording was kept") }
        self.peripheral = nil; status = "Reconnecting…"
        if wanted { connectIfPossible() }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let s = peripheral.services?.first(where: { $0.uuid == CBUUID(string: PocketBluetoothProtocol.service) }) else {
            status = "Pocket microphone service unavailable"; return
        }
        peripheral.discoverCharacteristics(nil, for: s)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { status = "Could not prepare pocket microphone"; return }
        for c in service.characteristics ?? [] {
            if c.uuid == CBUUID(string: PocketBluetoothProtocol.audio) { audio = c }
            if c.uuid == CBUUID(string: PocketBluetoothProtocol.events) { events = c }
            if c.uuid == CBUUID(string: PocketBluetoothProtocol.commands) { commands = c }
        }
        guard let audio, let events, commands != nil else { return }
        peripheral.setNotifyValue(true, for: audio); peripheral.setNotifyValue(true, for: events)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else { status = "Bluetooth pairing or subscription failed"; return }
        if audio?.isNotifying == true, events?.isNotifying == true {
            connected = true; status = "Connected"
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeer)
            onConnectionChanged?(true); arm()
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        if characteristic.uuid == CBUUID(string: PocketBluetoothProtocol.events) { handleEvent(value) }
        else if characteristic.uuid == CBUUID(string: PocketBluetoothProtocol.audio) { handleAudio(value) }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log.error("control write failed: \(error.localizedDescription, privacy: .public)") }
    }
}
