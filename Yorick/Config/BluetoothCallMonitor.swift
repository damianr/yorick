import AVFoundation
import CoreAudio

/// Notices a Bluetooth headset holding a call (HFP/eSCO voice) link.
///
/// WHY: an eSCO voice link reserves fixed Bluetooth radio airtime, and the
/// skulls' BLE audio notifications share that radio. FIELD-REPORTED
/// 2026-10-26: a Zoom call on AirPods Max made every Skull Mini dictation
/// overflow the skull's buffer ~2 s in, and the near-empty recording then
/// showed "No audio detected". The skulls also enumerate as USB microphones
/// when cabled, so during a call Yorick records from that instead.
enum BluetoothCallMonitor {
    /// The name of a Bluetooth input that is running at a voice-link rate,
    /// or nil. A2DP music runs at 44.1/48 kHz and doesn't count; HFP voice
    /// runs at 8–24 kHz.
    static func activeCallDeviceName() -> String? {
        for id in deviceIDs() {
            guard let transport: UInt32 = property(id, kAudioDevicePropertyTransportType),
                  transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  hasInputStreams(id),
                  let running: UInt32 = property(id, kAudioDevicePropertyDeviceIsRunningSomewhere), running != 0,
                  let rate: Float64 = property(id, kAudioDevicePropertyNominalSampleRate), rate <= 24_000
            else { continue }
            return name(id) ?? "a Bluetooth headset"
        }
        return nil
    }

    /// The cabled skull's USB microphone, if plugged in. Matched by name:
    /// "Skull Mini" for the Mini, any other "Skull" for the full skull.
    static func skullUSBMicrophone(mini: Bool) -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices.first { device in
                let name = device.localizedName
                guard name.localizedCaseInsensitiveContains("Skull") else { return false }
                return mini == name.localizedCaseInsensitiveContains("Mini")
            }
    }

    /// What the pill says when the skull's BLE audio failed. During a call the
    /// raw reason ("buffer overflowed") is replaced by the cause and the fix.
    static func failureMessage(_ reason: String, callDevice: String?) -> String {
        guard let callDevice else { return reason }
        return "Skull audio couldn’t keep up because \(callDevice) is on a Bluetooth call. Plug in the skull’s USB cable, or end the call."
    }

    // MARK: CoreAudio

    private static func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func hasInputStreams(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }
}
