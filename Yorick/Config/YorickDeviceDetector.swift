import Foundation
@preconcurrency import CoreBluetooth
import IOKit
import os

extension YorickDeviceKind {
    /// Yorick has connected to one of these before.
    @MainActor var isPaired: Bool {
        switch self {
        case .pocket: PocketBluetoothController.isPaired
        case .skull: SkullBluetoothController.isPaired
        case .mini: SkullMiniBluetoothController.isPaired
        }
    }
}

/// Notices a Yorick device that the Mac knows about and Yorick doesn't yet,
/// so Yorick can offer it as the mic. Nothing here asks for a permission:
/// people without the hardware never hear of it.
///
/// Two signals:
/// - Bluetooth, only once Yorick already has Bluetooth access. A device
///   paired in macOS Bluetooth settings is connected to the Mac and shows
///   up by its service UUID. Without access, creating a central would put
///   up the system prompt, so this side stays off.
/// - USB, always. A Yorick device on a charging cable shows up in IOKit by
///   its product name, which needs no permission.
@MainActor
final class YorickDeviceDetector: NSObject {
    /// Every kind the Mac shows, once per launch, offered or not.
    var onSeen: ((YorickDeviceKind) -> Void)?
    var onFound: ((YorickDeviceKind) -> Void)?
    /// Kinds Yorick already uses or has offered; never offered again.
    var isKnown: (YorickDeviceKind) -> Bool = { $0.isPaired }

    private var central: CBCentralManager?
    private var timer: Timer?
    private var notifyPort: IONotificationPortRef?
    private var usbIterator: io_iterator_t = 0
    private var seen: Set<YorickDeviceKind> = []
    private var offered: Set<YorickDeviceKind> = []
    private let log = Logger(subsystem: "com.heyyorick.Yorick", category: "deviceDetector")

    /// How the last search went, for Settings' Find card.
    enum Search: Equatable { case idle, searching, foundNothing, bluetoothOff, bluetoothDenied }
    private(set) var searchState: Search = .idle { didSet { if searchState != oldValue { onSearchChanged?(searchState) } } }
    var onSearchChanged: ((Search) -> Void)?
    /// True while Yorick is recording: no extra scanning then, it starves BLE audio.
    var isBusy: () -> Bool = { false }
    private var searchUntil: Date?
    private var searchFound = false
    private var lastBackgroundScan = Date.distantPast
    private var backgroundScanUntil: Date?
    static let searchDuration: TimeInterval = 30
    /// With Bluetooth allowed, a skull switched on later is noticed within ~20 s.
    static let backgroundScanEvery: TimeInterval = 20
    static let backgroundScanFor: TimeInterval = 2

    private static let dismissedKey = "dismissedYorickDevicePrompts"

    static var dismissed: Set<YorickDeviceKind> {
        get { Set((UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []).compactMap(YorickDeviceKind.init(rawValue:))) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: dismissedKey) }
    }

    func start() {
        watchUSB()
        if CBCentralManager.authorization == .allowedAlways { startBluetooth() }
    }

    private func startBluetooth() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    /// Asked for from Settings, or a skull's USB bridge was plugged in, so it
    /// may put up the Bluetooth permission prompt. On a Mac that has never
    /// seen a Yorick device this is the way to find one: a new skull isn't
    /// paired in macOS, and an MG24 board's USB has no Yorick product name.
    func search() {
        if CBCentralManager.authorization == .denied || CBCentralManager.authorization == .restricted {
            searchState = .bluetoothDenied; return
        }
        searchUntil = Date().addingTimeInterval(Self.searchDuration); searchFound = false
        searchState = .searching
        startBluetooth()
        updateScan()
    }

    var isSearching: Bool { searchUntil.map { Date() < $0 } ?? false }

    /// Some kind the Mac hasn't shown yet and Yorick isn't already using.
    private var anythingToFind: Bool {
        YorickDeviceKind.allCases.contains { !seen.contains($0) && !isKnown($0) }
    }

    private func tick() {
        checkBluetooth()
        if let until = searchUntil, Date() >= until {
            searchUntil = nil
            searchState = searchFound ? .idle : .foundNothing
        }
        if let until = backgroundScanUntil, Date() >= until { backgroundScanUntil = nil }
        if searchUntil == nil, backgroundScanUntil == nil, anythingToFind, !isBusy(),
           Date().timeIntervalSince(lastBackgroundScan) >= Self.backgroundScanEvery {
            lastBackgroundScan = Date()
            backgroundScanUntil = Date().addingTimeInterval(Self.backgroundScanFor)
        }
        updateScan()
    }

    private func updateScan() {
        guard let central, central.state == .poweredOn else { return }
        let want = (isSearching || backgroundScanUntil != nil) && !isBusy()
        if want, !central.isScanning {
            central.scanForPeripherals(withServices: YorickDeviceKind.allCases.map(\.service))
        } else if !want, central.isScanning {
            central.stopScan()
        }
    }

    private func report(_ kind: YorickDeviceKind, via source: String) {
        if seen.insert(kind).inserted { onSeen?(kind) }
        guard !isKnown(kind), !Self.dismissed.contains(kind), offered.insert(kind).inserted else { return }
        log.notice("found \(kind.rawValue, privacy: .public) over \(source, privacy: .public)")
        onFound?(kind)
    }

    // MARK: Bluetooth

    private func checkBluetooth() {
        guard let central, central.state == .poweredOn else { return }
        for kind in YorickDeviceKind.allCases where !seen.contains(kind) {
            if !central.retrieveConnectedPeripherals(withServices: [kind.service]).isEmpty {
                report(kind, via: "Bluetooth")
            }
        }
    }

    // MARK: USB

    private func watchUSB() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), { refcon, iterator in
            guard let refcon else { return }
            let detector = Unmanaged<YorickDeviceDetector>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { detector.drainUSB(iterator) }
        }, refcon, &usbIterator)
        guard result == KERN_SUCCESS else { log.error("USB watch failed: \(result)"); return }
        drainUSB(usbIterator) // arms the notification and covers what's already plugged in
    }

    private func drainUSB(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let name = ["USB Product Name", "kUSBProductString"].lazy.compactMap {
                IORegistryEntryCreateCFProperty(service, $0 as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            }.first
            if let name, let kind = YorickDeviceKind(usbProductName: name) { report(kind, via: "USB"); continue }
            // An MG24 skull's USB is the XIAO's own debug bridge: plugging
            // one in starts a Bluetooth search, which says which skull it is.
            let number = { (key: String) in
                (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            }
            if YorickDeviceKind.isSkullUSBBridge(vendor: number("idVendor"), product: number("idProduct"), name: name),
               anythingToFind, !isSearching, !isBusy() {
                log.notice("MG24 USB bridge plugged in; searching Bluetooth")
                search()
            }
        }
    }
}

extension YorickDeviceDetector: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        checkBluetooth()
        switch central.state {
        case .poweredOn: updateScan()
        case .unauthorized: if isSearching { searchUntil = nil; searchState = .bluetoothDenied }
        case .poweredOff: if isSearching { searchUntil = nil; searchState = .bluetoothOff }
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        guard let kind = YorickDeviceKind.allCases.first(where: { advertised.contains($0.service) }) else { return }
        if isSearching {
            // Found on request: offer it even if an earlier prompt was dismissed.
            if Self.dismissed.contains(kind) { Self.dismissed.remove(kind) }
            searchFound = true
        }
        report(kind, via: isSearching ? "search" : "scan")
        if isSearching, !anythingToFind { searchUntil = nil; searchState = .idle }
        updateScan()
    }
}
