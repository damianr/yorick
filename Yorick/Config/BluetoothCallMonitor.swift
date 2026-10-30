import AVFoundation
import CoreAudio

/// Notices Bluetooth audio busy enough to starve a skull's BLE audio.
///
/// WHY: the skulls' BLE audio notifications share the Mac's Bluetooth radio
/// with every other Bluetooth audio link. FIELD-REPORTED 2026-10-26: a Zoom
/// call on AirPods Max (an HFP/eSCO voice link, fixed reserved airtime) made
/// every Skull Mini dictation overflow the skull's buffer ~2 s in, and the
/// near-empty recording then showed "No audio detected". Music playing to
/// the same headphones (A2DP) did the same, and pausing it fixed it. The
/// skulls also enumerate as USB microphones when cabled, so while Bluetooth
/// audio is busy Yorick records from that instead.
enum BluetoothCallMonitor {
    struct BusyAudio: Equatable {
        /// The headset or speaker, as macOS names it.
        let device: String
        /// A call (voice link) rather than playback.
        let call: Bool

        var activity: String { call ? "on a call" : "playing audio" }
    }

    /// The Bluetooth audio device currently moving audio, or nil. A call
    /// shows as a Bluetooth input running at a voice-link rate (8–24 kHz);
    /// playback as a Bluetooth output that's running. A call wins when both.
    static func busyBluetoothAudio() -> BusyAudio? {
        var playing: BusyAudio?
        for id in deviceIDs() {
            guard let transport: UInt32 = property(id, kAudioDevicePropertyTransportType),
                  transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  let running: UInt32 = property(id, kAudioDevicePropertyDeviceIsRunningSomewhere), running != 0
            else { continue }
            let device = name(id) ?? "a Bluetooth headset"
            if hasStreams(id, scope: kAudioObjectPropertyScopeInput),
               let rate: Float64 = property(id, kAudioDevicePropertyNominalSampleRate), rate <= 24_000 {
                return BusyAudio(device: device, call: true)
            }
            if playing == nil, hasStreams(id, scope: kAudioObjectPropertyScopeOutput) {
                playing = BusyAudio(device: device, call: false)
            }
        }
        return playing
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

    /// What the pill says when the skull's BLE audio failed. With Bluetooth
    /// audio busy, the raw reason ("buffer overflowed") is replaced by the
    /// cause and the fix.
    static func failureMessage(_ reason: String, busy: BusyAudio?, supportsUSBMicrophone: Bool = true) -> String {
        guard let busy else { return reason }
        if !supportsUSBMicrophone {
            return "Skull audio couldn’t keep up while \(busy.device) was \(busy.activity) over Bluetooth. This MG24 skull doesn’t support USB audio. Try another microphone in Yorick for now."
        }
        let fix = busy.call ? "end the call" : "pause the audio"
        return "Skull audio couldn’t keep up because \(busy.device) is \(busy.activity) over Bluetooth. Plug in the skull’s USB cable, or \(fix)."
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

    private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
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
