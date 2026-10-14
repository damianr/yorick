import SwiftUI

/// The Yorick hardware block: the two microphones made for Yorick, which are
/// connected, which one is in use, and a one-tap way to add the other. With
/// nothing connected it doubles as a quiet introduction to the hardware.
struct YorickDevicesView: View {
    var session: SessionManager
    @State private var choosing = false
    @State private var skullHint = false
    @State private var showEyes = false

    enum Device: CaseIterable, Identifiable {
        case pocket, skull
        var id: Self { self }
        var name: String { self == .pocket ? "Yorick Pocket" : "Yorick Skull" }
        var blurb: String {
            self == .pocket
                ? "Handheld · Bluetooth · hold the button to talk"
                : "Desk mic · eyes that watch you speak"
        }
        var symbol: String { self == .pocket ? "mic.fill" : "eyes" }
    }

    private var mics: MicrophoneManager { session.microphoneManager }

    /// The skull shows up as a regular audio input (USB or its receiver).
    private var skullInput: MicrophoneDevice? {
        mics.devices.first { $0.isConnected && YorickEyeProtocol.isMicrophoneName($0.name) }
    }

    private var pocketKnown: Bool {
        session.pocketBluetooth.connected || mics.selectedDeviceUID == PocketBluetoothProtocol.deviceUID
    }

    private func isConnected(_ device: Device) -> Bool {
        device == .pocket ? session.pocketBluetooth.connected : skullInput != nil
    }

    private func isListed(_ device: Device) -> Bool {
        #if DEBUG
        // Settings snapshots can show the empty (no hardware) state.
        if ProcessInfo.processInfo.environment["YORICK_SNAPSHOT_NO_DEVICES"] != nil { return false }
        #endif
        return device == .pocket ? pocketKnown : skullInput != nil
    }

    private func isInUse(_ device: Device) -> Bool {
        switch device {
        case .pocket: mics.selectedDeviceUID == PocketBluetoothProtocol.deviceUID
        case .skull: skullInput.map { $0.id == mics.selectedDeviceUID } ?? false
        }
    }

    var body: some View {
        let listed = Device.allCases.filter(isListed)
        VStack(alignment: .leading, spacing: 8) {
            if listed.isEmpty && !choosing {
                introCard
            } else {
                ForEach(listed) { deviceRow($0) }
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
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Pieces

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
            Text("A handheld you hold to talk, and a desk skull whose eyes watch you speak. Both are made for Yorick and nothing else.")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.textTertiary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
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

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Which one?")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Cancel") {
                    withAnimation(.easeOut(duration: 0.15)) { choosing = false; skullHint = false }
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
            if skullHint {
                Text("Plug in the skull or its wireless receiver, then pick it again.")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.accentAmber)
                    .fixedSize(horizontal: false, vertical: true)
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
                if device == .skull, session.yorickMic.showEyeControls {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showEyes.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Eyes")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .semibold))
                                .rotationEffect(.degrees(showEyes ? 90 : 0))
                        }
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                        Text(device == .pocket && !connected ? "Reconnect" : "Use")
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
            if device == .skull, showEyes, session.yorickMic.showEyeControls {
                YorickMicSettingsView(mic: session.yorickMic)
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
        case .pocket:
            let s = session.pocketBluetooth.status
            return isInUse(.pocket) && session.pocketBluetooth.connected
                ? "\(s) · left button talks, right presses Return"
                : s
        case .skull:
            return session.yorickMic.showEyeControls ? "Connected · eyes ready" : "Connected"
        }
    }

    // MARK: - Actions

    private func connect(_ device: Device) {
        switch device {
        case .pocket:
            session.connectPocketBluetooth()
            choosing = false
        case .skull:
            if skullInput != nil {
                use(.skull); choosing = false; skullHint = false
            } else {
                skullHint = true
            }
        }
    }

    /// Picking a device also makes it the recording input.
    private func use(_ device: Device) {
        switch device {
        case .pocket:
            session.connectPocketBluetooth()
        case .skull:
            guard let skull = skullInput else { return }
            session.microphoneManager.selectedDeviceUID = skull.id
        }
    }
}
