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
        case setup
        case tryIt
        case done
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
    @State private var showShortcutRecorder = false
    @State private var setupHintLit = false
    /// Bumped when the shortcut is rebound — recording a new combo changes
    /// no SwiftUI state, so chips and keyboard highlights went stale.
    @State private var shortcutGeneration = 0

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
            case .setup: setup
            case .tryIt: tryIt
            case .done: done
            }

            Spacer()

            // Progress dots — clickable BACKWARD only. Revisiting a passed
            // step is harmless; jumping ahead would hop the permission
            // gates and finish onboarding into a broken install.
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Button {
                        guard s.rawValue < step.rawValue else { return }
                        withAnimation(.easeOut(duration: 0.2)) { step = s }
                    } label: {
                        Circle()
                            .fill(s == step ? Theme.accentPurple : Theme.bgElevated)
                            .frame(width: 6, height: 6)
                            .padding(4) // comfortable hit target
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .allowsHitTesting(s.rawValue < step.rawValue)
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
            loginItemEnabled = LoginItem.isEnabled
        }
        // KeyboardShortcuts' change notification (raw name; the library
        // doesn't export a constant) — chips and map re-render on rebind.
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
        )) { _ in
            shortcutGeneration += 1
            // A new combo landed — the form's job is done; chips and the
            // keyboard's fresh highlights carry the confirmation.
            withAnimation(.easeOut(duration: 0.2)) { showShortcutRecorder = false }
        }
    }

    // MARK: - Steps

    // No key combo here — the welcome step sells the idea, and the try-it
    // step teaches the keys with your hands already on them. Mechanics
    // before motivation read as homework.
    private var welcome: some View {
        stepLayout(
            icon: { logo },
            title: "Talk instead of type",
            lines: [
                "Hold the hotkey and speak. Let go, and it's typed.",
                "Not in a text field? It's saved. Nothing is lost."
            ]
        ) {
            primaryButton("Continue") { step = .setup }
        }
    }

    // The three asks as one checklist — a list you work down, not pages you
    // travel. No skips on the required two (mic: no product without it;
    // AX: a skipper meets a voice-notes app instead of the product); the
    // poll flips rows to granted the moment System Settings does.
    private var setup: some View {
        stepLayout(
            icon: { EmptyView() },
            title: "Grant Yorick access",
            lines: ["Everything runs on your Mac. Nothing is uploaded."]
        ) {
            VStack(spacing: 10) {
                setupRow(
                    icon: "mic.fill",
                    name: "Microphone",
                    why: "Hears what you say. Audio is transcribed on this Mac, then deleted.",
                    granted: microphoneGranted,
                    actionLabel: microphoneDenied ? "Open System Settings" : "Allow"
                ) {
                    if microphoneDenied {
                        openPrivacyPane("Privacy_Microphone")
                    } else {
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            DispatchQueue.main.async { microphoneGranted = granted }
                        }
                    }
                }
                setupRow(
                    icon: "keyboard.fill",
                    name: "Accessibility",
                    why: "Types into the app you're using, and sees whether a text field is focused.",
                    granted: accessibilityTrusted,
                    actionLabel: "Open System Settings"
                ) {
                    let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
                    AXIsProcessTrustedWithOptions(options)
                }
                setupRow(
                    icon: "power",
                    name: "Open at login",
                    why: "Starts Yorick when you log in.",
                    granted: loginItemEnabled,
                    actionLabel: "Turn On"
                ) {
                    loginItemEnabled = LoginItem.setEnabled(true)
                }
            }
            .frame(width: 500)
            // The hint holds the space above Continue, and answers a hover
            // on a not-yet-enabled Continue in white — a disabled button
            // that explains itself.
            Text(!isReady
                 ? "Microphone and Accessibility are required."
                 : (loginItemEnabled ? " " : "Open at login is optional."))
                .font(Theme.mono(10))
                .foregroundStyle(setupHintLit ? Color.white : Theme.textTertiary)
                .animation(.easeOut(duration: 0.15), value: setupHintLit)
            primaryButton("Continue") { step = .tryIt }
                .disabled(!isReady)
                .opacity(isReady ? 1 : 0.45)
                .onHover { hovering in setupHintLit = hovering && !isReady }
        }
    }

    private func setupRow(
        icon: String,
        name: String,
        why: String,
        granted: Bool,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(Theme.mono(12.5, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(why)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if granted {
                // Darker green than the text accent + a heavy check — the
                // light brand green washed out (prototype-measured).
                ZStack {
                    Circle()
                        .fill(Color(red: 0.17, green: 0.62, blue: 0.34))
                        .frame(width: 22, height: 22)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                }
            } else {
                Button(action: action) {
                    Text(actionLabel)
                        .font(Theme.mono(11, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.bgElevated))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }

    @ViewBuilder
    private var tryIt: some View {
        if isReady { tryItReady } else { tryItBlocked }
    }

    private var tryItReady: some View {
        stepLayout(
            icon: { logo },
            title: "Try it here",
            lines: []
        ) {
            // The instruction IS the chips — no glyph-decoding aside needed.
            HStack(spacing: 6) {
                Text("Click the box, then hold")
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.textSecondary)
                HotkeyChips()
                Text("and say a sentence.")
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            // The keyboard shows which keys — and lights up as they hold
            // them: right keys purple, wrong keys red. Hands, not prose.
            // `comboActive`: recording in progress means the full combo is
            // down (the hotkey machinery eats the final key's event, so the
            // monitor alone can never see the whole chord).
            KeyboardMapView(
                targetKeyCodes: ShortcutLabel.targetKeyCodes,
                comboActive: session.state == .recording
            )
            .id(shortcutGeneration) // re-highlight when the shortcut is rebound
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showShortcutRecorder.toggle() }
            } label: {
                Text("Set your own key combination")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .underline()
            }
            .buttonStyle(.plain)
            if showShortcutRecorder {
                CompactRecorderPill {
                    withAnimation(.easeOut(duration: 0.15)) { showShortcutRecorder = false }
                }
            }
            practiceField
            if !practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                grantedLabel("That's it. That's the whole app.")
            }
            primaryButton("Continue") { step = .done }
        }
    }

    private var done: some View {
        stepLayout(
            icon: { logo },
            title: "Yorick lives in your menu bar",
            lines: [
                "This window will close. Your saved items are under the skull.",
                "The hotkey works everywhere."
            ]
        ) {
            primaryButton("Start using Yorick") { onDone() }
        }
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
