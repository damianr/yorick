import AVFoundation
import CoreAudio

struct MicrophoneDevice: Identifiable, Hashable {
    let id: String    // AVCaptureDevice.uniqueID
    let name: String
    let isConnected: Bool
}

@MainActor
@Observable
final class MicrophoneManager {
    private(set) var devices: [MicrophoneDevice] = []
    var pocketConnected = false { didSet { refresh() } }
    var miniConnected = false { didSet { refresh() } }
    var skullConnected = false { didSet { refresh() } }

    /// Bluetooth inputs are Yorick's own devices, not CoreAudio inputs.
    var selectedIsBluetooth: Bool {
        selectedDeviceUID == PocketBluetoothProtocol.deviceUID || selectedDeviceUID == SkullBluetoothProtocol.deviceUID || selectedDeviceUID == SkullMiniBluetoothProtocol.deviceUID
    }

    /// nil means "system default". Persisted even when the device is unplugged
    /// so it auto-switches back when reconnected.
    var selectedDeviceUID: String? {
        didSet { UserDefaults.standard.set(selectedDeviceUID, forKey: "selectedMicUID") }
    }

    /// Whether the selected device is currently plugged in.
    var isSelectedDeviceAvailable: Bool {
        guard let uid = selectedDeviceUID else { return true } // "system default" is always available
        return devices.contains(where: { $0.id == uid && $0.isConnected })
    }

    /// The UID to actually use for recording — selected if available, otherwise nil (system default).
    var effectiveDeviceUID: String? {
        if selectedIsBluetooth { return selectedDeviceUID }
        return isSelectedDeviceAvailable ? selectedDeviceUID : nil
    }

    /// Name of the selected device for display, even if unplugged.
    var selectedDeviceName: String? {
        guard let uid = selectedDeviceUID else { return nil }
        return devices.first(where: { $0.id == uid })?.name
            ?? UserDefaults.standard.string(forKey: "selectedMicName")
    }

    private var listenerObjectID: AudioObjectID = AudioObjectID(kAudioObjectSystemObject)
    private var listenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: "selectedMicUID")
        refresh()
        startListening()
    }

    deinit {
        stopListening()
    }

    func refresh() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        var connectedDevices = session.devices.map {
            MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName, isConnected: true)
        }

        if pocketConnected || PocketBluetoothController.isPaired {
            connectedDevices.append(MicrophoneDevice(id: PocketBluetoothProtocol.deviceUID,
                name: PocketBluetoothProtocol.deviceName, isConnected: pocketConnected))
        }
        if skullConnected || SkullBluetoothController.isPaired {
            connectedDevices.append(MicrophoneDevice(id: SkullBluetoothProtocol.deviceUID,
                name: SkullBluetoothProtocol.deviceName, isConnected: skullConnected))
        }

        if miniConnected || SkullMiniBluetoothController.isPaired {
            connectedDevices.append(MicrophoneDevice(id: SkullMiniBluetoothProtocol.deviceUID,
                name: SkullMiniBluetoothProtocol.deviceName, isConnected: miniConnected))
        }

        // Keep the selected device in the list even if unplugged (so the picker shows it)
        var allDevices = connectedDevices
        if let uid = selectedDeviceUID,
           !connectedDevices.contains(where: { $0.id == uid }) {
            let savedName = UserDefaults.standard.string(forKey: "selectedMicName") ?? "Unknown Device"
            allDevices.append(MicrophoneDevice(id: uid, name: savedName, isConnected: false))
        }
        devices = allDevices

        // Save the name when the device is connected so we can show it when unplugged
        if let uid = selectedDeviceUID,
           let device = connectedDevices.first(where: { $0.id == uid }) {
            UserDefaults.standard.set(device.name, forKey: "selectedMicName")
        }
    }

    // MARK: - CoreAudio Device Change Listener

    private func startListening() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectAddPropertyListenerBlock(
            listenerObjectID,
            &listenerAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    nonisolated private func stopListening() {
        // Removing the listener is best-effort on deinit
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            { _, _ in }
        )
    }
}
