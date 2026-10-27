import Foundation
import Observation
#if YORICK_HARDWARE_LAB
import AVFoundation
import IOKit
import IOKit.serial
import Darwin
#endif

/// A non-serial eye transport (the skull over Bluetooth). Lines carry no newline.
@MainActor
protocol YorickEyeLink: AnyObject {
    var isLinkReady: Bool { get }
    func sendEyeLine(_ line: String)
    func takeEyeLines() -> [String]
}

/// Audio discovery and serial eye control (direct USB or wireless receiver) are independent. Opening
/// the control interface never opens an audio stream or changes the chosen mic. When the skull's
/// Bluetooth input is selected, the same eye protocol runs over `bluetoothLink` instead.
///
/// Public builds (no YORICK_HARDWARE_LAB) carry only the Bluetooth path, with the
/// default eye settings: no serial ports, no receiver, no tuning UI.
@MainActor @Observable
final class YorickMicController {
    private(set) var attached = false
    private(set) var controlsReady = false
    var showEyeControls: Bool { attached && controlsReady }
    private(set) var applied = false
    private(set) var needsInputSelection = false
    private(set) var status = "Connect a Yorick microphone to customize its eyes."
    var settings: YorickEyeSettings {
        didSet {
            settings.save(to: defaults, key: settingsKey)
            applied = false; dirtyAt = clock()
        }
    }
    var recording = false
    var stalled = false
    var recordingMicName: String?
    var audioLevel: Float = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastDiscovery = Date.distantPast
    @ObservationIgnored private var opened = Date.distantPast
    @ObservationIgnored private var lastHello = Date.distantPast
    @ObservationIgnored private var lastReply = Date.distantPast
    @ObservationIgnored private var lastSet = Date.distantPast
    @ObservationIgnored private var dirtyAt = Date.distantPast
    @ObservationIgnored private var sequence: UInt32 = 0
    @ObservationIgnored private var pendingSequence: UInt32?
    @ObservationIgnored private var pendingSettings: YorickEyeSettings?
    /// Each skull keeps its own eye settings.
    var miniSelected = false {
        didSet {
            guard miniSelected != oldValue else { return }
            // A Mini tuned before it had its own key starts from the shared settings.
            let key = defaults.data(forKey: settingsKey) == nil ? YorickEyeSettings.defaultsKey : settingsKey
            settings = YorickEyeSettings.load(from: defaults, key: key)
        }
    }
    private var settingsKey: String { miniSelected ? YorickEyeSettings.miniDefaultsKey : YorickEyeSettings.defaultsKey }
    var styleGroups: [(String, [YorickEyeStyle])] { miniSelected ? [("OLED", [.circular, .equalizer, .ember])] : YorickEyeStyle.groups }
    @ObservationIgnored weak var bluetoothLink: YorickEyeLink?
    @ObservationIgnored var bluetoothSelected: @MainActor () -> Bool = {
        [YorickEyeProtocol.bluetoothDeviceUID, SkullMiniBluetoothProtocol.deviceUID].contains(UserDefaults.standard.string(forKey: "selectedMicUID") ?? "")
    }
    @ObservationIgnored private var usingBluetooth = false
    @ObservationIgnored private var bluetoothWasReady = false
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let defaults: UserDefaults

    #if YORICK_HARDWARE_LAB
    @ObservationIgnored private var fd: Int32 = -1
    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var path: String?
    @ObservationIgnored private var audioDeviceCount = 0
    @ObservationIgnored private(set) var opening = false
    @ObservationIgnored private var openGeneration = UUID()
    @ObservationIgnored private var openingSince = Date.distantPast
    @ObservationIgnored private let configurePort: @Sendable (String) -> Int32

    typealias Inventory = (audioCount: Int, ports: [String])
    @ObservationIgnored private let discover: @MainActor () -> Inventory
    init(monitor: Bool = true, defaults: UserDefaults = .standard, discover: @escaping @MainActor () -> Inventory = YorickMicController.inventory, configurePort: @escaping @Sendable (String) -> Int32 = YorickMicController.configureSerialPort, clock: @escaping @MainActor () -> Date = { Date() }) {
        self.clock = clock
        self.configurePort = configurePort
        self.discover = discover
        self.defaults = defaults
        self.settings = YorickEyeSettings.load(from: defaults)
        if monitor { startMonitoring() }
    }
    deinit { task?.cancel(); if fd >= 0 { Darwin.close(fd) } }
    #else
    init(monitor: Bool = true, defaults: UserDefaults = .standard, clock: @escaping @MainActor () -> Date = { Date() }) {
        self.clock = clock
        self.defaults = defaults
        self.settings = YorickEyeSettings.load(from: defaults)
        if monitor { startMonitoring() }
    }
    deinit { task?.cancel() }
    #endif

    private func startMonitoring() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func retry() { disconnect(); lastDiscovery = .distantPast }

    /// Hide controls immediately when the input picker changes. Discovery still
    /// polls for system-default changes and physical USB/radio disconnects.
    func inputSelectionChanged() {
        bluetoothWasReady = false
        disconnect()
        attached = false; needsInputSelection = false
        lastDiscovery = .distantPast
        tick()
    }

    private func disconnect() {
        #if YORICK_HARDWARE_LAB
        openGeneration = UUID()
        if fd >= 0 { Self.closeOffMain(fd) }
        fd = -1; path = nil; buffer = ""
        #endif
        controlsReady = false; applied = false
        pendingSequence = nil; pendingSettings = nil
    }

    func tick() {
        let now = clock()
        if let link = bluetoothLink, bluetoothSelected() {
            if !usingBluetooth { disconnect(); usingBluetooth = true; bluetoothWasReady = false }
            needsInputSelection = false
            attached = link.isLinkReady
            guard attached else {
                if bluetoothWasReady { disconnect() }
                bluetoothWasReady = false
                status = "Turn on the skull to customize its eyes. Yorick reconnects over Bluetooth automatically."
                return
            }
            if !bluetoothWasReady {
                bluetoothWasReady = true; opened = now; lastHello = .distantPast; lastReply = now
                status = "Skull connected. Checking eye controls…"
            }
        } else {
            if usingBluetooth { usingBluetooth = false; disconnect(); attached = false; lastDiscovery = .distantPast }
            #if YORICK_HARDWARE_LAB
            guard serialTick(now) else { return }
            #else
            attached = false; status = "Connect a Yorick Skull over Bluetooth to light its eyes."
            return
            #endif
        }
        exchange(now)
    }

    #if YORICK_HARDWARE_LAB

    /// Serial discovery and open. Returns true once a port is open.
    private func serialTick(_ now: Date) -> Bool {
        if now.timeIntervalSince(lastDiscovery) >= 3 {
            lastDiscovery = now
            let inventory = discover()
            audioDeviceCount = inventory.audioCount
            attached = audioDeviceCount > 0
            let ports = inventory.ports
            needsInputSelection = audioDeviceCount > 1 || ports.count > 1
            // A selected transport resolves USB + receiver for the same skull.
            // Multiple devices on that same transport are still ambiguous.
            if !attached || audioDeviceCount != 1 || ports.count != 1 {
                disconnect()
                status = !attached ? "Connect a Yorick microphone to customize its eyes." : audioDeviceCount > 1 || ports.count > 1 ? "Choose the Yorick microphone input above to control its eyes. Keep only one device of that type connected." : "Microphone connected. Eye controls need a powered skull and compatible firmware on the skull and receiver."
                return false
            }
            if path != ports.first && !opening { disconnect(); openPort(ports[0]) }
        }
        if opening && now.timeIntervalSince(openingSince) > 3 {
            status = "Eye connection is not responding. Reconnect the skull or receiver; Yorick remains available."
        }
        return fd >= 0
    }

    private var transportOpen: Bool { usingBluetooth ? bluetoothLink?.isLinkReady == true : fd >= 0 }
    #else
    private var transportOpen: Bool { usingBluetooth && bluetoothLink?.isLinkReady == true }
    #endif

    private func exchange(_ now: Date) {
        readReplies()
        guard transportOpen else { return }
        if now.timeIntervalSince(lastHello) > 1 {
            lastHello = now
            send(YorickEyeProtocol.hello)
        }
        guard controlsReady else {
            if now.timeIntervalSince(opened) > 3 { status = "Microphone connected. Eye controls need a powered skull and compatible firmware on the skull and receiver." }
            return
        }
        if now.timeIntervalSince(lastReply) > 4 {
            disconnect(); if usingBluetooth { bluetoothWasReady = false }
            status = "Eye connection lost. Reconnecting…"; return
        }
        if applied && pendingSequence != nil && now.timeIntervalSince(lastSet) > 1 {
            applied = false
            status = "Microphone connected · syncing eyes…"
        }
        let current = settings.normalized()
        // Refresh settings so a brief skull power cycle also restores preferences,
        // even when the USB receiver never disconnected from this Mac.
        if now.timeIntervalSince(dirtyAt) > 0.2 &&
           ((!applied && (pendingSettings != current || now.timeIntervalSince(lastSet) > 1)) ||
            now.timeIntervalSince(lastSet) > 2) {
            sequence &+= 1; pendingSequence = sequence; pendingSettings = current; lastSet = now
            send(current.command(sequence: sequence))
        }
        // recordingMicName is AudioCapture's label for the active input; the
        // Bluetooth skull's is SkullBluetoothProtocol.deviceName.
        #if YORICK_HARDWARE_LAB
        let skullRecording = recordingMicName.map(YorickEyeProtocol.isMicrophoneName) == true
        #else
        let skullRecording = usingBluetooth && [SkullBluetoothProtocol.deviceName, SkullMiniBluetoothProtocol.deviceName].contains(recordingMicName ?? "")
        #endif
        let active = recording && !stalled && skullRecording
        let level = active ? settings.level(audioLevel) : 0
        send("YORICK STATE \(active ? 1 : 0) \(level)\n")
    }

    #if YORICK_HARDWARE_LAB
    private func openPort(_ candidate: String) {
        guard !opening else { return }
        opening = true; openingSince = clock()
        let generation = openGeneration
        let configure = configurePort
        status = "Microphone connected. Opening eye controls…"
        // O_NONBLOCK does not protect termios ioctl on macOS. A wedged USB
        // board can block tcsetattr for many seconds; never do it on MainActor.
        // Allow only one pending open, even after retry/unplug, to bound workers.
        Task { [weak self] in
            let handle = await Task.detached(priority: .utility) { configure(candidate) }.value
            guard let self else { if handle >= 0 { Self.closeOffMain(handle) }; return }
            self.opening = false
            guard generation == self.openGeneration else {
                if handle >= 0 { Self.closeOffMain(handle) }; return
            }
            guard handle >= 0 else {
                self.status = "Microphone connected. Eye connection unavailable; reconnect the skull or receiver, or retry."
                return
            }
            self.fd = handle; self.path = candidate; self.opened = self.clock(); self.lastHello = .distantPast
            self.status = "Microphone connected. Checking eye controls…"
        }
    }

    nonisolated private static func closeOffMain(_ handle: Int32) {
        Task.detached(priority: .utility) { Darwin.close(handle) }
    }

    nonisolated static func configureSerialPort(_ candidate: String) -> Int32 {
        let handle = Darwin.open(candidate, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else { return -1 }
        var options = termios()
        guard tcgetattr(handle, &options) == 0 else { Darwin.close(handle); return -1 }
        cfmakeraw(&options)
        cfsetispeed(&options, speed_t(B115200)); cfsetospeed(&options, speed_t(B115200))
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(HUPCL)
        guard tcsetattr(handle, TCSANOW, &options) == 0 else { Darwin.close(handle); return -1 }
        return handle
        // Never use the 1200-baud bootloader touch or toggle reset/DTR.
    }
    #endif

    private func send(_ message: String) {
        if usingBluetooth {
            bluetoothLink?.sendEyeLine(message.trimmingCharacters(in: .newlines)); return
        }
        #if YORICK_HARDWARE_LAB
        guard fd >= 0 else { return }
        let bytes = Array(message.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
        if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            // Temporary backpressure: next tick sends the latest state. Do not
            // repeatedly close/reopen a busy USB device.
            return
        }
        if written != bytes.count {
            // No unbounded queue or partial command retries on the UI thread.
            disconnect(); status = "Eye connection interrupted. Reconnecting…"
        }
        #endif
    }

    private func readReplies() {
        if usingBluetooth {
            for line in bluetoothLink?.takeEyeLines() ?? [] { handleReply(line) }
            return
        }
        #if YORICK_HARDWARE_LAB
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno != EAGAIN && errno != EWOULDBLOCK { disconnect() }
            return
        }
        guard count > 0 else { return }
        buffer += String(decoding: bytes.prefix(count), as: UTF8.self)
        if buffer.utf8.count > 4096 { buffer = ""; return }
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(...newline)
            handleReply(line)
        }
        #endif
    }

    private func handleReply(_ line: String) {
        if line == YorickEyeProtocol.ready {
            lastReply = clock(); controlsReady = true
            status = applied ? "Microphone connected · eyes ready" : "Microphone connected · syncing eyes…"
        } else if let ack = YorickEyeProtocol.acknowledgedSequence(line), ack == pendingSequence,
                  pendingSettings == settings.normalized() {
            applied = true; pendingSequence = nil
            lastReply = clock(); status = "Microphone connected · eyes ready"
        }
    }

    #if YORICK_HARDWARE_LAB
    struct ControlPort {
        let path: String
        let product: String
    }

    /// Route by the user's existing recording-input choice. USB power can leave
    /// both transports attached; a second transport is not a second target.
    static func resolveInventory(audioNames: [String], ports: [ControlPort], selectedMicrophoneName: String?) -> Inventory {
        let names = audioNames.filter(YorickEyeProtocol.isMicrophoneName)
        if let name = selectedMicrophoneName,
           let product = YorickEyeProtocol.controlProduct(forMicrophoneName: name),
           names.contains(name) {
            let count = names.filter { YorickEyeProtocol.controlProduct(forMicrophoneName: $0) == product }.count
            return (count, ports.filter { $0.product == product }.map(\.path).sorted())
        }
        // An unrelated or unavailable selected mic must never fall back to an
        // attached skull receiver. Its USB presence does not prove a live skull.
        return (0, [])
    }

    static func inventory() -> Inventory {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        let selectedUID = UserDefaults.standard.string(forKey: "selectedMicUID")
        let selected: AVCaptureDevice?
        if let selectedUID {
            selected = devices.first { $0.uniqueID == selectedUID }
        } else {
            selected = AVCaptureDevice.default(for: .audio)
        }
        return resolveInventory(audioNames: devices.map(\.localizedName), ports: controlPorts(), selectedMicrophoneName: selected?.localizedName)
    }

    /// Match the exact USB product on each serial device's ancestor.
    private static func controlPorts() -> [ControlPort] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var results: [ControlPort] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let value = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { continue }
            var node = service; IOObjectRetain(node)
            var matchedProduct: String?
            for _ in 0..<12 {
                if let product = IORegistryEntryCreateCFProperty(node, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                   YorickEyeProtocol.isControlProduct(product) { matchedProduct = product; break }
                var parent: io_registry_entry_t = 0
                if IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) != KERN_SUCCESS { break }
                IOObjectRelease(node); node = parent
            }
            IOObjectRelease(node)
            if let product = matchedProduct { results.append(ControlPort(path: value, product: product)) }
        }
        return results
    }
    #endif
}
