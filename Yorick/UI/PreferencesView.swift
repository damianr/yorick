import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import KeyboardShortcuts

/// Hide the window toolbar background when supported. `.toolbarBackgroundVisibility`
/// is macOS 15+, so the modifier is a no-op on macOS 14.
struct HiddenWindowToolbarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

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
                settingsRow {
                    VStack(alignment: .leading, spacing: 3) {
                        rowLabel("Hold to talk")
                        caption("Hold to record, release to finish. In a text field your words are typed; anywhere else they're saved.")
                    }
                    Spacer(minLength: 16)
                    ShortcutRecorderView(name: .toggleSession, label: "")
                        .frame(maxWidth: 200)
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

                Text("yorick \(version) · everything on this Mac · no account · no analytics")
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
        .background(Theme.bgPrimary)
        .navigationTitle("Settings")
        .modifier(HiddenWindowToolbarBackground())
        .onAppear {
            session.microphoneManager.refresh()
            refreshPermissionState()
            activeMicrophoneMode = Self.currentMicrophoneModeName()
        }
    }

    /// The zero-download engine when this OS has it; the legacy on-device
    /// recognizer otherwise (macOS 14–25).
    private var preferredAppleEngine: TranscriptionEngine {
        TranscriptionEngine.appleAnalyzer.isAvailableOnThisOS ? .appleAnalyzer : .apple
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
        TranscriptionEngine.preferred = engine
        switch engine {
        case .whisper:
            ensureWhisperReady()
        case .apple:
            if !appleSpeechAuthorized {
                Task { appleSpeechAuthorized = await AppleSpeech.requestAuthorization() }
            }
        case .appleAnalyzer:
            break
        }
    }

    /// Switching to Whisper mid-run must fetch the model and boot the server —
    /// launch only does this when Whisper is already the preference.
    private func ensureWhisperReady() {
        if FileManager.default.fileExists(atPath: WhisperServer.modelPath) {
            Task.detached { WhisperServer.ensureRunning() }
            return
        }
        whisperDownloading = true
        Task.detached {
            do {
                try await WhisperServer.downloadModelIfNeeded { _ in }
                await WhisperServer.downloadVADModelIfNeeded()
                WhisperServer.ensureRunning()
            } catch {
                print("[Settings] Whisper model download failed: \(error)")
            }
            await MainActor.run { whisperDownloading = false }
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
