import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import KeyboardShortcuts

/// Settings in the stream's language: quiet rows, eyebrow section labels,
/// three disclosure styles — always-visible caption for the row that defines
/// the product, in-card copy for the engine choice, tooltip for trivia.
/// Diagnostics exist only for admin builds (`defaults write … adminMode 1`).
struct SettingsView: View {
    var session: SessionManager
    @State private var selectedEngine: TranscriptionEngine = TranscriptionEngine.preferred
    @State private var appleSpeechAuthorized = AppleSpeech.isAvailable
    @State private var microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var activeMicrophoneMode = SettingsView.currentMicrophoneModeName()
    @State private var whisperDownloading = false
    @AppStorage(AudioDebugSettings.keepAudioKey) private var keepDebugAudio = AudioDebugSettings.defaultKeepAudio
    @AppStorage(SessionManager.cleanupDictationKey) private var cleanupDictation = false
    @AppStorage(Telemetry.shareUsageCountsKey) private var shareUsageCounts = true
    @AppStorage(HUDPlacement.unanchoredAtTopKey) private var unanchoredPillAtTop = true
    @State private var opensAtLogin = LoginItem.isEnabled
    @ObservedObject private var linear = LinearSettings.shared
    @ObservedObject private var sendController = LinearSendController.shared
    @State private var connecting = false
    @State private var screenRecordingGranted = ScreenCapture.isAuthorized
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
                sectionLabel("RECORDING")
                // The onboarding try-it's hotkey block, verbatim: chips, the
                // live keyboard map, rebinding as a quiet link — teach by
                // hands here too, not a bare recorder field.
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel("Hold to talk")
                        caption("Hold to record, release to finish. In a text field your words are typed; anywhere else they're saved.")
                    }
                    HotkeyEditorView()
                        .environment(session)
                        .padding(.vertical, 4)
                }
                .padding(.vertical, 10)
                settingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel("Clean up dictation before it types")
                        caption("Removes filler words and false starts on this Mac, then types the result — adds a beat before the text lands. If cleanup can't run, your words are typed exactly as spoken. Your list always keeps the original.")
                    }
                    Spacer(minLength: 16)
                    Toggle("", isOn: $cleanupDictation)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: cleanupDictation) {
                            Telemetry.send(.cleanupToggled, ["enabled": String(cleanupDictation)])
                        }
                }
                settingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel("Saved-note position")
                        caption("Where the recording pill and saved-note card appear when you're not in a text field. Dictation into a field always shows the pill at the field.")
                    }
                    Spacer(minLength: 16)
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

                sectionLabel("MICROPHONE")
                settingsRow {
                    rowLabel("Input")
                    Spacer()
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
                    .frame(maxWidth: 230)
                }
                if mics.selectedDeviceUID != nil, !mics.isSelectedDeviceAvailable {
                    caption("Selected device is unplugged — using system default until reconnected.")
                        .padding(.top, 4)
                }

                sectionLabel("TRANSCRIPTION")
                VStack(spacing: 8) {
                    engineCard(
                        engine: preferredAppleEngine,
                        name: "Apple Speech",
                        sub: "fastest · no download · recommended",
                        desc: "Apple's on-device engine. Text appears about as fast as you release the key, and there's nothing to set up."
                    )
                    engineCard(
                        engine: .whisper,
                        name: "Whisper",
                        sub: "best accuracy · 600 MB download",
                        desc: "Downloads a 600 MB model once, then runs on this Mac. A touch slower; slightly better with unusual words — and it learns your product names.",
                        statusLine: whisperDownloading ? "downloading model…" : nil
                    )
                }

                sectionLabel("PERMISSIONS & SYSTEM")
                settingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel("Open at login")
                        caption("Yorick only hears the key while it's running.")
                    }
                    Spacer(minLength: 16)
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
                settingsRow {
                    rowLabel("Mic mode")
                    Spacer()
                    Text(activeMicrophoneMode)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                    infoDot
                        .help("A macOS setting, not ours — it filters your mic before Yorick hears it. Voice Isolation is best for dictation; if transcripts get worse in a noisy room, check here first.")
                    pillButton("Open") {
                        if #available(macOS 12.0, *) {
                            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                        }
                        activeMicrophoneMode = Self.currentMicrophoneModeName()
                    }
                }

                sectionLabel("PRIVACY")
                settingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel("Share anonymous usage counts")
                        caption("Counts like \"a dictation was typed\" — so we learn what's used. Never your words, your audio, or where you typed them. Every event is listed in TELEMETRY.md in the public repo.")
                    }
                    Spacer(minLength: 16)
                    Toggle("", isOn: $shareUsageCounts)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }

                linearSection

                sectionLabel("PRIVACY")
                settingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel("Share anonymous usage counts")
                        caption("Counts like \"a dictation was typed\" — so we learn what's used. Never your words, your audio, or where you typed them. Every event is listed in TELEMETRY.md in the public repo.")
                    }
                    Spacer(minLength: 16)
                    Toggle("", isOn: $shareUsageCounts)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }

                sectionLabel("UPDATES")
                settingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel("Version \(version)")
                        caption("Update checks and the usage counts above are Yorick's only routine network calls, and every update is cryptographically signed. Nothing about what you say is ever sent.")
                    }
                    Spacer(minLength: 16)
                    pillButton("Check Now") {
                        NotificationCenter.default.post(name: .checkForUpdates, object: nil)
                    }
                }
                settingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel("Check automatically")
                        caption("Looks once a day and asks before installing.")
                    }
                    Spacer(minLength: 16)
                    Toggle("", isOn: $automaticUpdateChecks)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }

                if adminMode {
                    sectionLabel("DIAGNOSTICS · ADMIN BUILD ONLY", tint: Theme.accentCoral.opacity(0.7))
                    settingsRow {
                        VStack(alignment: .leading, spacing: 3) {
                            rowLabel("Keep audio recordings")
                            caption("Off by default — recordings are discarded the moment transcription finishes. Turn on only to debug microphone problems.")
                        }
                        Spacer(minLength: 16)
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

    // MARK: - Linear

    /// The only place in Yorick where user content can leave the Mac, so the
    /// copy here does the whole job of saying so — plainly, in the flat
    /// declarative register the rest of the app uses, and without persuasion.
    @ViewBuilder
    private var linearSection: some View {
        sectionLabel("LINEAR")
        settingsRow {
            VStack(alignment: .leading, spacing: 3) {
                rowLabel(linear.isConnected
                    ? (linear.workspaces.all.count > 1
                       ? "Connected to \(linear.workspaces.all.count) Linear workspaces"
                       : "Connected to \(linear.workspaces.all.first?.organizationName ?? "Linear")")
                    : "Send captures to Linear")
                caption(linear.isConnected
                    ? "Saved captures get a Send button. You see the issue — title, team, project, and every line of context — before anything is sent, and nothing is sent until you press Create issue. Each connection covers one workspace; add as many as you like and pick the team on every send."
                    : "Off by default. Connecting lets you turn a saved capture into a Linear issue, and does two things Yorick otherwise never does: saved captures start recording what was on screen around them — what was selected, the page open, what you pointed at — and pressing Send transmits that capture to Linear. Both are shown to you in full before anything is sent, and neither happens while this is off.")
            }
            Spacer(minLength: 16)
            if linear.isConnected {
                // ADD, not switch. Connecting a second workspace used to
                // replace the first silently; now each one is its own
                // connection with its own row below.
                if connecting {
                    pillButton("Cancel") { sendController.cancelConnect() }
                } else {
                    pillButton("Add workspace") {
                        connecting = true
                        Task {
                            await sendController.connect()
                            connecting = false
                        }
                    }
                }
            } else if LinearConfig.isConfigured {
                if connecting {
                    pillButton("Cancel") { sendController.cancelConnect() }
                } else {
                    pillButton("Connect") {
                        connecting = true
                        Task {
                            await sendController.connect()
                            connecting = false
                        }
                    }
                }
            } else {
                Text("unavailable in this build")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }

        if let status = sendController.connectionStatus {
            Text(status)
                .font(Theme.mono(9.5))
                .foregroundStyle(status.hasPrefix("Couldn't") || status.hasPrefix("Connection cancelled")
                                 ? Theme.accentAmber : Theme.success)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
        }

        if linear.isConnected {
            ForEach(linear.workspaces.all, id: \.organizationID) { workspace in
                settingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel(workspace.organizationName ?? "Linear")
                        caption("\(workspace.teams.count) team\(workspace.teams.count == 1 ? "" : "s"), "
                                + "\(workspace.projects.count) project\(workspace.projects.count == 1 ? "" : "s")")
                    }
                    Spacer(minLength: 16)
                    pillButton("Disconnect") {
                        if let id = workspace.organizationID {
                            Task { await sendController.disconnect(workspaceID: id) }
                        }
                    }
                }
            }
            settingsRow {
                VStack(alignment: .leading, spacing: 3) {
                    rowLabel("Default team")
                    caption("Where a capture goes when nothing better fits. You can change it on every send.")
                }
                Spacer(minLength: 16)
                Picker("", selection: $linear.defaultTeamID) {
                    Text("—").tag(String?.none)
                    ForEach(linear.workspaces.teams) { ref in
                        Text(ref.label(qualified: linear.workspaces.needsWorkspaceQualifier))
                            .tag(String?.some(ref.team.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 160)
            }
            settingsRow {
                VStack(alignment: .leading, spacing: 3) {
                    rowLabel("Let this Mac draft the issue")
                    caption("Uses Apple's on-device model to suggest a title and pick the project, from your real teams and projects. Nothing is sent to do this. Off means you get the transcript and your default team, which is also what you get whenever the model can't help.")
                }
                Spacer(minLength: 16)
                Toggle("", isOn: $linear.composeWithModel)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!IssueComposer.isAvailable)
            }
            settingsRow {
                VStack(alignment: .leading, spacing: 3) {
                    rowLabel("Screen context")
                    caption("While this integration is on, every capture also records what was selected, the page or document open, and what you pointed at — so an issue makes sense to someone who wasn't there. Dictations included, so a capture is still filable when it typed somewhere you didn't mean. It goes nowhere until you send. Turn the integration off and none of it is read at all.")
                }
                Spacer(minLength: 16)
                pillButton("Refresh projects") {
                    Task { await sendController.refreshWorkspaces() }
                }
            }
            settingsRow {
                VStack(alignment: .leading, spacing: 3) {
                    rowLabel("Screenshots")
                    caption("A camera button appears on the recording pill when you're not in a text field: drag a region while you're still talking and the crop rides along. In a field it's left out on purpose, since clicking it would blur what you're dictating into — attach one from the capture's page afterwards instead. Optional, and the only feature that needs Screen Recording. Screenshots stay on your Mac until you send, and you can delete one first.")
                }
                Spacer(minLength: 16)
                if screenRecordingGranted {
                    grantedLabel
                } else {
                    pillButton("Allow") {
                        _ = ScreenCapture.requestAuthorization()
                        screenRecordingGranted = ScreenCapture.isAuthorized
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private func sectionLabel(_ text: String, tint: Color = Theme.textTertiary) -> some View {
        Text(text)
            .font(Theme.mono(8.5))
            .tracking(1.6)
            .foregroundStyle(tint)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }

    private func settingsRow(@ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) {
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

    private var infoDot: some View {
        Text("i")
            .font(Theme.mono(8))
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 13, height: 13)
            .overlay(Circle().stroke(Theme.borderSubtle, lineWidth: 1))
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
                Text(desc)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
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
