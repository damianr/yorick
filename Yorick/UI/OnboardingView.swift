import SwiftUI
import AVFoundation
import ApplicationServices
import KeyboardShortcuts

/// First-run flow: what Yorick does, the two permissions it needs, and a
/// ten-second first dictation. Zero configuration by design — no accounts,
/// no keys, no downloads on the default path.
struct OnboardingView: View {
    let onDone: () -> Void
    @Environment(SessionManager.self) private var session

    private enum Step: Int, CaseIterable {
        case welcome
        case microphone
        case accessibility
        case autostart
        case tryIt
    }

    @State private var step: Step = .welcome
    @State private var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var practiceText = ""
    @State private var loginItemEnabled = LoginItem.isEnabled
    @FocusState private var practiceFocused: Bool
    /// Whether the trigger has ever fired since we reached the practice step. If
    /// it hasn't after a while, the likeliest cause is another app already owning
    /// the shortcut (⌥Space is Raycast's default, and Handy's), which otherwise
    /// looks exactly like "Yorick is broken".
    @State private var hotkeyFired = false
    @State private var showConflictHelp = false

    private let axPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The live shortcut, so onboarding never tells the user to press a key that
    /// isn't bound (it's remappable, and the default has changed before).
    private var shortcut: String { ShortcutLabel.symbols }
    /// Same trigger, named in words for anyone who doesn't read ⌥ as "Option".
    private var shortcutSpelled: String { ShortcutLabel.spelled }

    /// Dictation needs both permissions: the microphone to hear, Accessibility to
    /// type. Missing either means the app cannot do its one job.
    private var isReady: Bool { microphoneGranted && accessibilityTrusted }

    private var missingPermissions: [String] {
        var missing: [String] = []
        if !microphoneGranted { missing.append("Microphone") }
        if !accessibilityTrusted { missing.append("Accessibility") }
        return missing
    }

    /// macOS prompts for the mic exactly once. After a denial the only route is
    /// System Settings, so the button has to change or the step is a dead end.
    private var microphoneDenied: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            switch step {
            case .welcome: welcome
            case .microphone: microphone
            case .accessibility: accessibility
            case .autostart: autostart
            case .tryIt: tryIt
            }

            Spacer()

            // Progress dots — clickable, for iterating on the flow (and a
            // harmless affordance for users who want to peek ahead or back).
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { step = s }
                    } label: {
                        Circle()
                            .fill(s == step ? Theme.accentPurple : Theme.bgElevated)
                            .frame(width: 6, height: 6)
                            .padding(4) // comfortable hit target
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPrimary)
        .onReceive(axPoll) { _ in
            // Granting Accessibility happens in System Settings — poll so the
            // step advances the moment the toggle flips, no relaunch needed.
            accessibilityTrusted = AXIsProcessTrusted()
            microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if session.state != .idle { hotkeyFired = true }
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        stepLayout(
            icon: { logo },
            title: "Talk instead of type",
            lines: [
                "Hold  \(shortcut)  and speak. Release to finish.",
                "(that's \(shortcutSpelled))",
                "In a text field, your words are typed.",
                "Anywhere else, they're saved for later.",
                "Everything happens on your Mac. Nothing is uploaded, ever."
            ]
        ) {
            primaryButton("Continue") { step = .microphone }
        }
    }

    private var microphone: some View {
        stepLayout(
            icon: { stepIcon("mic.fill", granted: microphoneGranted) },
            title: "Microphone",
            lines: [
                "Yorick needs the microphone to hear you.",
                "Audio is transcribed on this Mac and the recording is discarded."
            ]
        ) {
            if microphoneGranted {
                grantedLabel("Microphone access granted")
                primaryButton("Continue") { step = .accessibility }
            } else if microphoneDenied {
                // Already denied: macOS won't ask again, so send them to Settings.
                primaryButton("Open Microphone Settings") {
                    openPrivacyPane("Privacy_Microphone")
                }
                quietButton("Skip for now — Yorick can't hear you until this is on") {
                    step = .accessibility
                }
            } else {
                primaryButton("Allow Microphone Access") {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            microphoneGranted = granted
                            if granted { step = .accessibility }
                        }
                    }
                }
                quietButton("Skip for now — Yorick can't hear you until this is on") {
                    step = .accessibility
                }
            }
        }
    }

    private var accessibility: some View {
        stepLayout(
            icon: { stepIcon("keyboard.fill", granted: accessibilityTrusted) },
            title: "Accessibility",
            lines: [
                "This is how Yorick types into the app you're using,",
                "and how it knows whether a text field is focused.",
                "macOS asks you to enable it in System Settings."
            ]
        ) {
            if accessibilityTrusted {
                grantedLabel("Accessibility enabled")
                primaryButton("Continue") { step = .autostart }
            } else {
                primaryButton("Open Accessibility Settings") {
                    let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
                    AXIsProcessTrustedWithOptions(options)
                }
                quietButton("Skip for now — dictation won't type until enabled") {
                    step = .autostart
                }
            }
        }
    }

    private var autostart: some View {
        stepLayout(
            icon: { stepIcon("power", granted: loginItemEnabled) },
            title: "Always ready",
            lines: [
                "Yorick only hears the key while it's running.",
                "Open it at login so dictation is one hold away after every restart.",
                "You can change this anytime in System Settings or Yorick's settings."
            ]
        ) {
            if loginItemEnabled {
                grantedLabel("Opens at login")
                primaryButton("Continue") { step = .tryIt }
            } else {
                primaryButton("Open at Login") {
                    loginItemEnabled = LoginItem.setEnabled(true)
                    if loginItemEnabled { step = .tryIt }
                }
                quietButton("Not now") { step = .tryIt }
            }
        }
    }

    @ViewBuilder
    private var tryIt: some View {
        if isReady { tryItReady } else { tryItBlocked }
    }

    private var tryItReady: some View {
        stepLayout(
            icon: { logo },
            title: "Try it here",
            lines: [
                "Click the box, then hold  \(shortcut)  and say a sentence.",
                "That's \(shortcutSpelled). Release when you're done."
            ]
        ) {
            practiceField
            if practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if showConflictHelp && !hotkeyFired {
                    conflictHelp
                } else {
                    Text("It works the same in every app. No text field focused? Your words are saved to this window instead.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
            } else {
                grantedLabel("That's it. That's the whole app.")
            }
            primaryButton("Start using Yorick") { onDone() }
            Text("Yorick lives in your menu bar — click the skull to see everything you've saved.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
        }
        .task(id: step) {
            // Only arm the hint once we're actually asking them to press it.
            guard step == .tryIt else { return }
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if !hotkeyFired { showConflictHelp = true }
        }
    }

    /// Shown when the trigger hasn't fired after a beat: the failure a user can't
    /// diagnose alone. Rebinding is offered right here rather than in Settings,
    /// because this is the moment they discover it.
    private var conflictHelp: some View {
        VStack(spacing: 8) {
            Text("Nothing happening?")
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(Theme.accentAmber)
            Text("Another app may already use \(shortcut). Launchers like Raycast and other dictation apps often claim it. Pick a different trigger:")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            ShortcutRecorderView(name: .toggleSession, label: "")
                .frame(maxWidth: 220)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Theme.accentAmber.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Theme.accentAmber.opacity(0.25), lineWidth: 1)
        )
    }

    /// Skipping a permission used to land here anyway, on a practice box that
    /// could never work. Say plainly what's missing and offer the way to fix it
    /// instead of pretending there's something to try.
    private var tryItBlocked: some View {
        stepLayout(
            icon: {
                ZStack {
                    Circle().fill(Theme.accentAmber.opacity(0.12)).frame(width: 72, height: 72)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(Theme.accentAmber)
                }
            },
            title: "Not ready yet",
            lines: [
                "Yorick needs \(missingPermissions.joined(separator: " and ")) to work.",
                "Until then, holding \(shortcut) will do nothing at all."
            ]
        ) {
            VStack(spacing: 8) {
                if !microphoneGranted {
                    primaryButton("Turn on Microphone") {
                        if microphoneDenied {
                            openPrivacyPane("Privacy_Microphone")
                        } else {
                            AVCaptureDevice.requestAccess(for: .audio) { granted in
                                DispatchQueue.main.async { microphoneGranted = granted }
                            }
                        }
                    }
                }
                if !accessibilityTrusted {
                    primaryButton("Turn on Accessibility") {
                        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
                        AXIsProcessTrustedWithOptions(options)
                    }
                }
            }
            Text("This screen updates the moment you flip the switch.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
            quietButton("Finish anyway — you can turn these on later in Settings") {
                onDone()
            }
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// A real text field, so the first dictation happens right here in the
    /// window: the pill appears, the words land, and the product is understood
    /// without leaving onboarding.
    private var practiceField: some View {
        TextEditor(text: $practiceText)
            .font(Theme.mono(12))
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(width: 400, height: 84)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bgElevated))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(practiceFocused ? Theme.accentPurple.opacity(0.5) : Theme.borderSubtle, lineWidth: 1)
            )
            .focused($practiceFocused)
            .onAppear {
                // Give the step transition a beat before grabbing focus, so the
                // caret (and the pill that anchors to it) lands in a settled view.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    practiceFocused = true
                }
            }
    }

    // MARK: - Pieces

    private func stepLayout(
        @ViewBuilder icon: () -> some View,
        title: String,
        lines: [String],
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(spacing: 18) {
            icon()
            Text(title)
                .font(Theme.mono(18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            VStack(spacing: 5) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            VStack(spacing: 10) {
                actions()
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: 440)
    }

    private var logo: some View {
        ZStack {
            Circle()
                .fill(Theme.bgElevated)
                .frame(width: 72, height: 72)
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .frame(width: 32, height: 32)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func stepIcon(_ systemName: String, granted: Bool) -> some View {
        ZStack {
            Circle()
                .fill(granted ? Theme.success.opacity(0.1) : Theme.bgElevated)
                .frame(width: 72, height: 72)
            Image(systemName: granted ? "checkmark" : systemName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(granted ? Theme.success : Theme.textSecondary)
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.mono(12, weight: .semibold))
                .foregroundStyle(Theme.bgPrimary)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.accentPurple))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    private func grantedLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
            Text(text)
                .font(Theme.mono(11, weight: .medium))
        }
        .foregroundStyle(Theme.success)
    }

    private func quietButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
