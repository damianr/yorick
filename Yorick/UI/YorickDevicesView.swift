import SwiftUI

/// The Yorick hardware block: one row per Yorick device this Mac has
/// connected, which one is in use, and that device's own settings (a
/// skull's eyes). A model that's never been connected doesn't appear, and
/// with none the block shows nothing: the app never mentions the hardware
/// until one turns up (see YorickDeviceDetector). The lab build keeps the
/// introduction card and the picker for pairing a model from here.
struct YorickDevicesView: View {
    var session: SessionManager
    @State private var choosing = false

    enum Device: CaseIterable, Identifiable {
        case pocket, skull, mini
        var id: Self { self }
        var name: String { self == .pocket ? "Yorick Pocket" : self == .mini ? "Yorick Skull Mini" : "Yorick Skull" }
        var blurb: String {
            self == .mini ? "Compact mic · Bluetooth · OLED eyes" : self == .pocket
                ? "Handheld · Bluetooth · hold the button to talk"
                : "Desk mic · Bluetooth · eyes that watch you speak"
        }
        var symbol: String { self == .pocket ? "mic.fill" : "eyes" }
    }

    private var mics: MicrophoneManager { session.microphoneManager }

    /// A wired skull (USB or the old receiver) shows up as a regular audio input.
    /// Public builds only know the skull over Bluetooth.
    private var skullInput: MicrophoneDevice? {
        #if YORICK_HARDWARE_LAB
        mics.devices.first { $0.isConnected && $0.id != SkullBluetoothProtocol.deviceUID && $0.id != SkullMiniBluetoothProtocol.deviceUID && YorickEyeProtocol.isMicrophoneName($0.name) }
        #else
        nil
        #endif
    }

    private var showsEyeTuning: Bool { session.yorickMic.showEyeControls }

    private var skullBluetoothKnown: Bool {
        session.skullBluetooth.connected || mics.selectedDeviceUID == SkullBluetoothProtocol.deviceUID
            || SkullBluetoothController.isPaired || session.detectedDevices.contains(.skull)
    }

    private var pocketKnown: Bool {
        session.pocketBluetooth.connected || mics.selectedDeviceUID == PocketBluetoothProtocol.deviceUID
            || PocketBluetoothController.isPaired || session.detectedDevices.contains(.pocket)
    }

    private func isConnected(_ device: Device) -> Bool {
        device == .mini ? session.skullMiniBluetooth.connected : device == .pocket ? session.pocketBluetooth.connected : session.skullBluetooth.connected || skullInput != nil
    }

    private func battery(_ device: Device) -> DeviceBattery? {
        device == .mini ? session.skullMiniBluetooth.battery : device == .pocket ? session.pocketBluetooth.battery : session.skullBluetooth.battery
    }

    private func isListed(_ device: Device) -> Bool {
        #if DEBUG
        // Settings snapshots can show the empty (no hardware) state.
        if ProcessInfo.processInfo.environment["YORICK_SNAPSHOT_NO_DEVICES"] != nil { return false }
        #endif
        return device == .mini ? (session.skullMiniBluetooth.connected || SkullMiniBluetoothController.isPaired || mics.selectedDeviceUID == SkullMiniBluetoothProtocol.deviceUID || session.detectedDevices.contains(.mini)) : device == .pocket ? pocketKnown : skullBluetoothKnown || skullInput != nil
    }

    private func isInUse(_ device: Device) -> Bool {
        switch device {
        case .mini: mics.selectedDeviceUID == SkullMiniBluetoothProtocol.deviceUID
        case .pocket: mics.selectedDeviceUID == PocketBluetoothProtocol.deviceUID
        case .skull: mics.selectedDeviceUID == SkullBluetoothProtocol.deviceUID
            || (skullInput.map { $0.id == mics.selectedDeviceUID } ?? false)
        }
    }

    var body: some View {
        let listed = Device.allCases.filter(isListed)
        #if !YORICK_HARDWARE_LAB
        if !listed.isEmpty { devices(listed) }
        #else
        devices(listed)
        #endif
    }

    private func devices(_ listed: [Device]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if listed.isEmpty && !choosing {
                #if YORICK_HARDWARE_LAB
                introCard
                #endif
            } else {
                ForEach(listed) { deviceRow($0) }
                #if YORICK_HARDWARE_LAB
                if choosing {
                    picker
                } else if listed.count < Device.allCases.count {
                    Button("Connect another Yorick device") {
                        withAnimation(.easeOut(duration: 0.15)) { choosing = true }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textSecondary)
                    .underline()
                    .padding(.top, 2)
                }
                #endif
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Pieces

    #if YORICK_HARDWARE_LAB
    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                Image(systemName: "eyes")
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.bone.opacity(0.8))
            Text("Yorick has hardware.")
                .font(Theme.mono(11.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("A handheld you hold to talk, and a desk skull whose eyes watch you speak. Build one and it connects over Bluetooth, for Yorick alone.")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textTertiary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Link("How to build one", destination: URL(string: "https://github.com/damianr/yorick-mics")!)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textSecondary)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { choosing = true }
            } label: {
                Text("Connect a Yorick device")
                    .font(Theme.mono(10, weight: .medium))
                    .foregroundStyle(Theme.bgPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.bone))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bone.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.bone.opacity(0.14), lineWidth: 1))
    }
    #endif

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Which one?")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Cancel") {
                    withAnimation(.easeOut(duration: 0.15)) { choosing = false }
                }
                .buttonStyle(.plain)
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: 8) {
                ForEach(Device.allCases.filter { !isListed($0) }) { device in
                    Button { connect(device) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: device.symbol)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.bone.opacity(0.85))
                            Text(device.name)
                                .font(Theme.mono(10.5, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(device.blurb)
                                .font(Theme.mono(8.5))
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bgCard))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.borderDefault, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func deviceRow(_ device: Device) -> some View {
        let connected = isConnected(device)
        let inUse = isInUse(device)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(connected ? Theme.bone : Theme.textTertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(Theme.mono(11.5))
                        .foregroundStyle(Theme.textPrimary)
                    Text(statusText(device))
                        .font(Theme.mono(9))
                        .foregroundStyle(connected ? Theme.success : Theme.textTertiary)
                }
                Spacer(minLength: 8)
                if connected, let battery = battery(device) {
                    BatteryBadge(battery: battery, showsDetail: true)
                }
                if inUse {
                    Text("in use")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.bone)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(Capsule().stroke(Theme.bone.opacity(0.35), lineWidth: 1))
                } else {
                    Button { use(device) } label: {
                        Text(!connected ? "Reconnect" : "Use")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.bgElevated))
                            .overlay(Capsule().stroke(Theme.borderSubtle, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if device != .pocket, inUse, showsEyeTuning {
                YorickCompactEyeControls(mic: session.yorickMic)
                    .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(inUse ? Theme.bone.opacity(0.04) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(inUse ? Theme.bone.opacity(0.3) : Theme.borderSubtle, lineWidth: 1)
        )
    }

    private func statusText(_ device: Device) -> String {
        switch device {
        case .mini: return session.skullMiniBluetooth.status
        case .pocket:
            let s = session.pocketBluetooth.status
            return isInUse(.pocket) && session.pocketBluetooth.connected
                ? "\(s) · left button talks, right presses Return"
                : s
        case .skull:
            if mics.selectedDeviceUID == SkullBluetoothProtocol.deviceUID || skullInput == nil {
                let s = session.skullBluetooth.status
                return session.skullBluetooth.connected && session.yorickMic.showEyeControls ? "\(s) · eyes ready" : s
            }
            return session.yorickMic.showEyeControls ? "Connected · eyes ready" : "Connected"
        }
    }

    // MARK: - Actions

    private func connect(_ device: Device) {
        switch device {
        case .mini:
            session.connectSkullMiniBluetooth(); choosing = false
        case .pocket:
            session.connectPocketBluetooth()
            choosing = false
        case .skull:
            use(.skull); choosing = false
        }
    }

    /// Picking a device also makes it the recording input.
    private func use(_ device: Device) {
        switch device {
        case .mini:
            session.connectSkullMiniBluetooth(); choosing = false
        case .pocket:
            session.connectPocketBluetooth()
        case .skull:
            // Bluetooth is the skull's own link. A wired skull stays available
            // in the microphone picker.
            session.connectSkullBluetooth()
        }
    }
}

/// A device's battery: icon and percent, red when it needs charging.
struct BatteryBadge: View {
    let battery: DeviceBattery
    var showsDetail = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: battery.symbol)
                .font(.system(size: 11))
            Text(showsDetail ? battery.label : "\(battery.percent)%")
                .font(Theme.mono(9))
        }
        .foregroundStyle(battery.isLow ? Theme.error : Theme.textSecondary)
        .help(help)
    }

    private var help: String {
        var parts = [battery.isLow ? "Battery low — charge soon" : "Battery \(battery.percent)%"]
        if let mv = battery.millivolts { parts.append(String(format: "%.2f V", Double(mv) / 1000)) }
        return parts.joined(separator: " · ")
    }
}
