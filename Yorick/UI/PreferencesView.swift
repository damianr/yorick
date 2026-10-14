import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import KeyboardShortcuts

/// Settings in the stream's language: quiet rows, eyebrow section labels.
/// The hotkey leads, the microphone (Yorick hardware first) follows, and
/// every description stays folded under its row's caret so the page fits.
/// Diagnostics exist only for admin builds (`defaults write … adminMode 1`).
struct SettingsView: View {
    var session: SessionManager
    @State private var selectedEngine: TranscriptionEngine = TranscriptionEngine.preferred
    @State private var appleSpeechAuthorized = AppleSpeech.isAvailable
    @State private var microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var activeMicrophoneMode = SettingsView.currentMicrophoneModeName()
    @State private var whisperDownloading = false
    /// Rows whose description is unfolded. Descriptions start folded so the
    /// page fits; the caret (or a hover tooltip) reveals them.
    @State private var expanded: Set<String> = []
    @AppStorage(AudioDebugSettings.keepAudioKey) private var keepDebugAudio = AudioDebugSettings.defaultKeepAudio
    @AppStorage(SessionManager.cleanupDictationKey) private var cleanupDictation = false
    @AppStorage(Telemetry.shareUsageCountsKey) private var shareUsageCounts = true
    @AppStorage(HUDPlacement.unanchoredAtTopKey) private var unanchoredPillAtTop = true
    @State private var opensAtLogin = LoginItem.isEnabled
    /// Sparkle reads this key straight from UserDefaults, so binding to it is
    /// enough to turn scheduled checks on and off.
    @AppStorage("SUEnableAutomaticChecks") private var automaticUpdateChecks = true

    /// Never shown to users; enabled per-machine for the founder's builds.
    private var adminMode: Bool { UserDefaults.standard.bool(forKey: "adminMode") }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        @Bindable var mics = session.microphoneManager

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The onboarding try-it's hotkey block, verbatim: chips, the
                // live keyboard map, rebinding as a quiet link — teach by
                // hands here too, not a bare recorder field.
                VStack(alignment: .leading, spacing: 10) {
                    disclosureLabel("hold", "Hold to talk",
                        info: "Hold to record, release to finish. In a text field your words are typed; anywhere else they're saved.")
                    HotkeyEditorView()
                        .environment(session)
                        .padding(.vertical, 4)
                }
                .padding(.top, 18)
                .padding(.bottom, 4)

                // Hardware first: which mic Yorick hears is the next thing
                // anyone checks after the key.
                sectionLabel("MICROPHONE")
                YorickDevicesView(session: session)
                infoRow("input", "Input",
                        info: "Any microphone this Mac can hear. Picking a Yorick device above selects it here for you.") {
                    Picker("", selection: $mics.selectedDeviceUID) {
                        Text("System Default").tag(String?.none)
                        if !mics.devices.isEmpty {
                            Divider()
                            ForEach(mics.devices) { device in
                                Text(device.isConnected ? device.name : "\(device.name) (unplugged)")
                                    .tag(Optional(device.id))
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 210)
                }
                if mics.selectedDeviceUID != nil, !mics.isSelectedDeviceAvailable,
                   !mics.selectedIsBluetooth {
                    caption("Selected device is unplugged — using system default until reconnected.")
                        .padding(.top, 4)
                }
                infoRow("micmode", "Mic mode",
                        info: "A macOS setting, not ours — it filters your mic before Yorick hears it. Voice Isolation is best for dictation; if transcripts get worse in a noisy room, check here first.") {
                    Text(activeMicrophoneMode)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                    pillButton("Open") {
                        if #available(macOS 12.0, *) {
                            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                        }
                        activeMicrophoneMode = Self.currentMicrophoneModeName()
                    }
                }

                sectionLabel("TRANSCRIPTION")
                VStack(spacing: 8) {
                    engineCard(
                        engine: preferredAppleEngine,
                        name: "Apple Speech",
                        sub: "fastest · recommended",
                        desc: "Apple's on-device engine. Text appears about as fast as you release the key, and there's nothing to set up."
                    )
                    engineCard(
                        engine: .whisper,
                        name: "Whisper",
                        sub: "best accuracy · 600 MB",
                        desc: "Downloads a 600 MB model once, then runs on this Mac. A touch slower; slightly better with unusual words — and it learns your product names.",
                        statusLine: whisperDownloading ? "downloading model…" : nil
                    )
                }

                sectionLabel("RECORDING")
                infoRow("cleanup", "Clean up before typing",
                        info: "Removes filler words and false starts on this Mac, then types the result — adds a beat before the text lands. If cleanup can't run, your words are typed exactly as spoken. Your list always keeps the original.") {
                    Toggle("", isOn: $cleanupDictation)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: cleanupDictation) {
                            Telemetry.send(.cleanupToggled, ["enabled": String(cleanupDictation)])
                        }
                }
                infoRow("position", "Saved-note position",
                        info: "Where the recording pill and saved-note card appear when you're not in a text field. Dictation into a field always shows the pill at the field.") {
                    Picker("", selection: $unanchoredPillAtTop) {
                        Text("Top center").tag(true)
                        Text("Bottom center").tag(false)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)
                    .onChange(of: unanchoredPillAtTop) {
                        // Move the live HUD immediately — no relaunch to see it.
                        NotificationCenter.default.post(name: .hudReposition, object: nil)
                    }
                }

                sectionLabel("PERMISSIONS & SYSTEM")
                infoRow("login", "Open at login",
                        info: "Yorick only hears the key while it's running.") {
                    Toggle("", isOn: Binding(
                        get: { opensAtLogin },
                        set: { opensAtLogin = LoginItem.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }
                settingsRow {
                    rowLabel("Microphone")
                    Spacer()
                    if microphoneAuthorized {
                        grantedLabel
                    } else {
                        neededLabel
                        pillButton(AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined ? "Grant" : "Open") {
                            handleMicrophonePermission()
                        }
                    }
                }
                settingsRow {
                    rowLabel("Accessibility")
                    Spacer()
                    if accessibilityTrusted {
                        grantedLabel
                    } else {
                        neededLabel
                        pillButton("Open") { openPrivacyPane("Privacy_Accessibility") }
                    }
                }

                sectionLabel("PRIVACY & UPDATES")
                infoRow("usage", "Share anonymous usage counts",
                        info: "Counts like \"a dictation was typed\" — so we learn what's used. Never your words, your audio, or where you typed them. Every event is listed in TELEMETRY.md in the public repo.") {
                    Toggle("", isOn: $shareUsageCounts)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                infoRow("autoupdate", "Check for updates daily",
                        info: "Looks once a day and asks before installing. Update checks and the usage counts are Yorick's only routine network calls, and every update is cryptographically signed. Nothing about what you say is ever sent.") {
                    Toggle("", isOn: $automaticUpdateChecks)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                settingsRow {
                    rowLabel("Version \(version)")
                    Spacer(minLength: 16)
                    pillButton("Check Now") {
                        NotificationCenter.default.post(name: .checkForUpdates, object: nil)
                    }
                }

                if adminMode {
                    sectionLabel("DIAGNOSTICS · ADMIN BUILD ONLY", tint: Theme.accentCoral.opacity(0.7))
                    infoRow("keepaudio", "Keep audio recordings",
                            info: "Off by default — recordings are discarded the moment transcription finishes. Turn on only to debug microphone problems.") {
                        Toggle("", isOn: $keepDebugAudio)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }

                Text("yorick \(version) · your words stay on this Mac · no account")
                    .font(Theme.mono(8.5))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        // No opaque background: settings render as a page of the menu bar
        // panel, whose glass shows through.
        .onChange(of: mics.selectedDeviceUID) {
            session.pocketBluetooth.selectionChanged()
            session.skullSelectionChanged()
            session.yorickMic.inputSelectionChanged()
        }
        .onChange(of: mics.isSelectedDeviceAvailable) {
            session.yorickMic.inputSelectionChanged()
        }
        .onAppear {
            session.microphoneManager.refresh()
            refreshPermissionState()
            activeMicrophoneMode = Self.currentMicrophoneModeName()
            opensAtLogin = LoginItem.isEnabled
        }
    }

    /// The zero-download engine when this OS has it; the legacy on-device
    /// recognizer otherwise (macOS 14–25).
    private var preferredAppleEngine: TranscriptionEngine {
        TranscriptionEngine.appleAnalyzer.isAvailableOnThisOS ? .appleAnalyzer : .apple
    }

    // MARK: - Pieces

    /// A row label with a caret that unfolds its description underneath.
    /// The description is also the hover tooltip.
    private func disclosureLabel(_ id: String, _ label: String, info: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) {
                    if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
                }
            } label: {
                HStack(spacing: 6) {
                    rowLabel(label)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded.contains(id) ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(info)
            if expanded.contains(id) {
                caption(info)
            }
        }
    }

    private func infoRow(_ id: String, _ label: String, info: String,
                         @ViewBuilder control: () -> some View) -> some View {
        settingsRow {
            disclosureLabel(id, label, info: info)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }

    private func sectionLabel(_ text: String, tint: Color = Theme.textTertiary) -> some View {
        Text(text)
            .font(Theme.mono(8.5))
            .tracking(1.6)
            .foregroundStyle(tint)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }

    private func settingsRow(@ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            content()
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.textPrimary)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(9.5))
            .foregroundStyle(Theme.textTertiary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var grantedLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
            Text("granted")
                .font(Theme.mono(10))
        }
        .foregroundStyle(Theme.success)
    }

    private var neededLabel: some View {
        Text("needs access")
            .font(Theme.mono(10))
            .foregroundStyle(Theme.accentAmber)
    }

    private func pillButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
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

    private func engineCard(
        engine: TranscriptionEngine,
        name: String,
        sub: String,
        desc: String,
        statusLine: String? = nil
    ) -> some View {
        let selected = selectedEngine == engine
        return Button(action: { selectEngine(engine) }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Circle()
                        .stroke(selected ? Theme.accentPurple : Theme.textTertiary, lineWidth: 1.5)
                        .frame(width: 11, height: 11)
                        .overlay(
                            Circle()
                                .fill(selected ? Theme.accentPurple : Color.clear)
                                .frame(width: 5, height: 5)
                        )
                    Text(name)
                        .font(Theme.mono(11, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(sub)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let statusLine {
                    Text(statusLine)
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.accentAmber)
                        .padding(.leading, 21)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? Theme.accentPurple.opacity(0.05) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? Theme.accentPurple.opacity(0.45) : Theme.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(desc)
    }

    // MARK: - Actions

    private func selectEngine(_ engine: TranscriptionEngine) {
        selectedEngine = engine
        switch engine {
        case .whisper:
            ensureWhisperReady()
        case .apple:
            TranscriptionEngine.preferred = engine
            if !appleSpeechAuthorized {
                Task { appleSpeechAuthorized = await AppleSpeech.requestAuthorization() }
            }
        case .appleAnalyzer:
            TranscriptionEngine.preferred = engine
        }
    }

    /// Switching to Whisper mid-run must fetch the model and boot the server —
    /// launch only does this when Whisper is already the preference. The live
    /// preference flips only once the model is on disk: dictations during the
    /// 600 MB download keep using the engine that was already working, and a
    /// failed download rolls the card back instead of stranding the user on an
    /// engine that can't run.
    private func ensureWhisperReady() {
        if FileManager.default.fileExists(atPath: WhisperServer.modelPath) {
            TranscriptionEngine.preferred = .whisper
            Task.detached { WhisperServer.ensureRunning() }
            return
        }
        let previousEngine = TranscriptionEngine.preferred
        whisperDownloading = true
        Task.detached {
            do {
                try await WhisperServer.downloadModelIfNeeded { _ in }
                await WhisperServer.downloadVADModelIfNeeded()
                WhisperServer.ensureRunning()
                await MainActor.run {
                    // Commit only if the user hasn't picked another engine
                    // while the download ran.
                    if selectedEngine == .whisper { TranscriptionEngine.preferred = .whisper }
                    whisperDownloading = false
                }
            } catch {
                print("[Settings] Whisper model download failed: \(error)")
                await MainActor.run {
                    if selectedEngine == .whisper { selectedEngine = previousEngine }
                    whisperDownloading = false
                }
            }
        }
    }

    private func refreshPermissionState() {
        microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityTrusted = AXIsProcessTrusted()
    }

    private func handleMicrophonePermission() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                await MainActor.run { microphoneAuthorized = granted }
            }
        } else {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func currentMicrophoneModeName() -> String {
        guard #available(macOS 12.0, *) else { return "Unavailable" }
        switch AVCaptureDevice.activeMicrophoneMode {
        case .standard: return "Standard"
        case .wideSpectrum: return "Wide Spectrum"
        case .voiceIsolation: return "Voice Isolation"
        @unknown default: return "Unknown"
        }
    }
}
