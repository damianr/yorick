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
    var onFound: ((YorickDeviceKind) -> Void)?
    /// Kinds Yorick already uses or has offered; never offered again.
    var isKnown: (YorickDeviceKind) -> Bool = { $0.isPaired }

    private var central: CBCentralManager?
    private var timer: Timer?
    private var notifyPort: IONotificationPortRef?
    private var usbIterator: io_iterator_t = 0
    private var offered: Set<YorickDeviceKind> = []
    private let log = Logger(subsystem: "com.heyyorick.Yorick", category: "deviceDetector")

    private static let dismissedKey = "dismissedYorickDevicePrompts"

    static var dismissed: Set<YorickDeviceKind> {
        get { Set((UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []).compactMap(YorickDeviceKind.init(rawValue:))) }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: dismissedKey) }
    }

    func start() {
        watchUSB()
        if CBCentralManager.authorization == .allowedAlways, central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkBluetooth() }
            }
            RunLoop.main.add(t, forMode: .common); timer = t
        }
    }

    private func report(_ kind: YorickDeviceKind, via source: String) {
        guard !isKnown(kind), !Self.dismissed.contains(kind), offered.insert(kind).inserted else { return }
        log.notice("found \(kind.rawValue, privacy: .public) over \(source, privacy: .public)")
        onFound?(kind)
    }

    // MARK: Bluetooth

    private func checkBluetooth() {
        guard let central, central.state == .poweredOn else { return }
        for kind in YorickDeviceKind.allCases where !offered.contains(kind) {
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
            if let name, let kind = YorickDeviceKind(usbProductName: name) { report(kind, via: "USB") }
        }
    }
}

extension YorickDeviceDetector: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) { checkBluetooth() }
}
