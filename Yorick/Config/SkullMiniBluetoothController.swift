import Foundation
@preconcurrency import CoreBluetooth
import os

/// The skull over Bluetooth LE: audio while Yorick is listening, and the same
/// eye-control lines the USB/receiver serial path carries. The Mac starts and
/// stops sessions from its hotkey or the skull’s debounced button states.
@MainActor
@Observable
final class SkullMiniBluetoothController: NSObject, YorickEyeLink {
    private(set) var status = "Not connected"
    private(set) var connected = false
    private(set) var battery: DeviceBattery? { didSet { if battery != oldValue { onBatteryChanged?(battery) } } }
    var onBatteryChanged: ((DeviceBattery?) -> Void)?
    private(set) var receivedFrames = 0
    private(set) var missingSamples = 0
    var onTalkButton: ((Bool) -> Void)?
    var onReturnButton: (() -> Void)?
    private var buttons = SkullButtonState()
    private var buttonSeenAt = Date.distantPast
    private var buttonHeld = false
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
    private var stopRequestedAt: Date?
    /// Current skull firmware sends Opus; older firmware, 4-bit ADPCM.
    private let opusDecoder = OpusPacketDecoder()
    private var lastAudio = Date.distantPast
    private var reconnectAfter = Date.distantPast
    /// When the pending connect began. CoreBluetooth never times one out.
    private var connectingSince = Date.distantPast
    /// Another skull of this model seen advertising while the remembered one
    /// hasn't answered (it's switched off, or it's the other board).
    private var standby: CBPeripheral?
    private var batteryCharacteristics: [CBCharacteristic] = []
    private var batteryReadAt = Date.distantPast
    private var eyeLines: [String] = []
    private let log = Logger(subsystem: "com.heyyorick.Yorick", category: "skullMiniBLE")
    static let savedPeer = "skullMiniBluetoothPeer"

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
        assembler = .init(session: session); stopTarget = nil; stopDeadline = nil; opusDecoder?.reset()
        receivedFrames = 0; missingSamples = 0; lastAudio = Date()
        write(SkullMiniBluetoothProtocol.listen(session), reliable: true)
        log.notice("listen session=\(self.session)")
        return true
    }

    /// Ask the skull to flush its tail; onStop fires once the audio is complete.
    func stopListening() {
        guard assembler != nil, stopDeadline == nil else { return }
        write(SkullMiniBluetoothProtocol.stopListening, reliable: true)
        stopDeadline = Date().addingTimeInterval(0.8); stopRequestedAt = Date()
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
        // Reason first: onStop finalizes the partial recording, and its
        // processing must know why it's short instead of blaming the mic.
        onFailure?(reason)
        if had { onStop?() }
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
              let data = SkullMiniBluetoothProtocol.encode(line) else { return }
        if reliable { p.writeValue(data, for: c, type: .withResponse) }
        else if p.canSendWriteWithoutResponse { p.writeValue(data, for: c, type: .withoutResponse) }
    }

    // MARK: Link

    private func connectIfPossible() {
        guard wanted, central?.state == .poweredOn, peripheral == nil else { return }
        if let value = UserDefaults.standard.string(forKey: Self.savedPeer), let id = UUID(uuidString: value),
           let peer = central?.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = peer; peer.delegate = self; status = "Connecting…"
            connectingSince = Date(); standby = nil
            central?.connect(peer)
            // A pending connect to a switched-off skull waits forever, so also
            // look for any skull that's on (see tick).
            central?.scanForPeripherals(withServices: [CBUUID(string: SkullMiniBluetoothProtocol.service)]); return
        }
        guard allowNew else { status = "Skull unavailable"; return }
        // Paired in macOS Bluetooth settings, it's already connected to the
        // Mac and has stopped advertising, so a scan alone would never find it.
        if let peer = central?.retrieveConnectedPeripherals(withServices: [CBUUID(string: SkullMiniBluetoothProtocol.service)]).first {
            peripheral = peer; peer.delegate = self; status = "Connecting…"
            connectingSince = Date(); central?.connect(peer); return
        }
        status = "Looking for the skull…"
        central?.scanForPeripherals(withServices: [CBUUID(string: SkullMiniBluetoothProtocol.service)])
    }
    private func resetButtons() {
        if buttonHeld { onTalkButton?(false) }
        buttonHeld = false; buttons = SkullButtonState(); buttonSeenAt = .distantPast
    }
    private func tick() {
        if buttonSeenAt != .distantPast, Date().timeIntervalSince(buttonSeenAt) > 1.5 { resetButtons() }
        // Notifications carry changes; a slow poll keeps voltage fresh and covers older firmware.
        if connected, !batteryCharacteristics.isEmpty, Date().timeIntervalSince(batteryReadAt) > 60 {
            batteryReadAt = Date(); batteryCharacteristics.forEach { peripheral?.readValue(for: $0) }
        }
        if let pending = peripheral, !connected, pending.state != .connected,
           Date().timeIntervalSince(connectingSince) > 4 {
            if let other = standby, other.identifier != pending.identifier {
                log.notice("remembered skull not answering; connecting to another")
                central?.cancelPeripheralConnection(pending)
                peripheral = other; other.delegate = self; standby = nil
                connectingSince = Date(); status = "Connecting…"
                central?.connect(other)
            } else if Date().timeIntervalSince(connectingSince) > 8 {
                status = "Waiting for the skull. Is it on?"
            }
        }
        if wanted, peripheral == nil, Date() >= reconnectAfter {
            reconnectAfter = Date().addingTimeInterval(3); connectIfPossible()
        }
        // Busy Bluetooth (music, a call) leaves the skull seconds behind; it
        // keeps flushing its backlog after release, so wait while frames are
        // still arriving, up to 6 s, rather than cut the tail at 0.8 s.
        if let deadline = stopDeadline, Date() >= deadline, assembler != nil,
           Date().timeIntervalSince(lastAudio) < 0.4, let asked = stopRequestedAt,
           Date().timeIntervalSince(asked) < 6 {
            stopDeadline = Date().addingTimeInterval(0.3)
        } else if let deadline = stopDeadline, Date() >= deadline {
            if let a = assembler, let target = stopTarget, a.expectedOffset < target {
                missingSamples += Int(target - a.expectedOffset)
                log.error("tail missing samples=\(target - a.expectedOffset)")
            }
            finish()
        } else if assembler != nil, stopDeadline == nil, Date().timeIntervalSince(lastAudio) > 2 {
            write(SkullMiniBluetoothProtocol.stopListening, reliable: true)
            fail("Skull audio stopped arriving; the partial recording was kept")
        }
    }
    private func handleReply(_ data: Data) {
        guard let line = String(data: data, encoding: .ascii), let reply = SkullMiniBluetoothProtocol.parse(line) else { return }
        switch reply {
        case .buttons(let down, let count):
            buttonSeenAt = Date()
            let events = buttons.accept(down: down, returns: count)
            if let held = events.talk { buttonHeld = held; onTalkButton?(held) }
            for _ in 0..<events.returns { onReturnButton?() }
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
        guard var a = assembler else { return }
        let frame: PocketBluetoothProtocol.Frame?
        if let opus = PocketBluetoothProtocol.OpusFrame(data) {
            // Opus decoding carries state from packet to packet: only this session's.
            guard opus.session == a.session, let opusDecoder else { return }
            frame = opus.frame(opusDecoder)
        } else {
            frame = PocketBluetoothProtocol.Frame(data)
        }
        guard let frame, let samples = a.accept(frame) else { return }
        assembler = a; receivedFrames = a.frames; missingSamples = a.missingSamples
        lastAudio = Date(); onSamples?(samples)
        if let target = stopTarget, a.expectedOffset >= target { finish() }
    }
}

extension SkullMiniBluetoothController: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connectIfPossible()
        case .unauthorized: status = "Allow Yorick to use Bluetooth in System Settings"
        case .poweredOff: status = "Bluetooth is off"
        default: status = "Bluetooth unavailable"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if let pending = self.peripheral {
            // Waiting on the remembered skull; tick switches if it never answers.
            if !connected, pending.identifier != peripheral.identifier { standby = peripheral }
            return
        }
        guard allowNew else { return }
        self.peripheral = peripheral; peripheral.delegate = self; central.stopScan()
        connectingSince = Date(); status = "Connecting…"; central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { central.cancelPeripheralConnection(peripheral); return }
        central.stopScan(); standby = nil
        log.notice("link up \(peripheral.name ?? "unnamed", privacy: .public)")
        status = "Preparing encrypted connection…"
        peripheral.discoverServices([CBUUID(string: SkullMiniBluetoothProtocol.service), DeviceBattery.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // A skull given up on in favour of another reports here too.
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        self.peripheral = nil; reconnectAfter = Date().addingTimeInterval(3)
        status = "Connection failed — retrying…"
        log.error("connection failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        let was = connected
        resetButtons()
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
        guard error == nil, let s = peripheral.services?.first(where: { $0.uuid == CBUUID(string: SkullMiniBluetoothProtocol.service) }) else {
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
            if c.uuid == CBUUID(string: SkullMiniBluetoothProtocol.audio) { audio = c }
            if c.uuid == CBUUID(string: SkullMiniBluetoothProtocol.replies) { replies = c }
            if c.uuid == CBUUID(string: SkullMiniBluetoothProtocol.control) { control = c }
        }
        guard let audio, let replies, control != nil else { return }
        peripheral.setNotifyValue(true, for: audio); peripheral.setNotifyValue(true, for: replies)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if batteryCharacteristics.contains(characteristic) { return }
        guard error == nil else {
            log.error("subscribe failed: \(error?.localizedDescription ?? "", privacy: .public)")
            status = "Bluetooth pairing or subscription failed"; return
        }
        if audio?.isNotifying == true, replies?.isNotifying == true, !connected {
            connected = true; status = "Connected"; allowNew = false
            log.notice("connected \(peripheral.name ?? "unnamed", privacy: .public)")
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeer)
            onConnectionChanged?(true)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        if batteryCharacteristics.contains(characteristic) {
            battery = DeviceBattery.updated(battery, uuid: characteristic.uuid, value: value)
            if let b = battery { log.notice("battery \(b.percent)% mv=\(b.millivolts ?? 0) charging=\(b.charging) usb=\(b.usbPower)") }
            return
        }
        if characteristic.uuid == CBUUID(string: SkullMiniBluetoothProtocol.replies) { handleReply(value) }
        else if characteristic.uuid == CBUUID(string: SkullMiniBluetoothProtocol.audio) { handleAudio(value) }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log.error("control write failed: \(error.localizedDescription, privacy: .public)") }
    }
}
