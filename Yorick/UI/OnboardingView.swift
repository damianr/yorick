import SwiftUI
import AVFoundation
import ApplicationServices
import KeyboardShortcuts

/// First-run flow, reordered 2026-08-02 for the capture-first positioning
/// (see docs/positioning-reversal-proposal.md).
///
/// The CAPTURE try-it leads and the dictation reveal closes, inverting what
/// this flow used to teach. The reasoning is the positioning's: filing a
/// ticket about the thing in front of you is the job nobody else does, and
/// dictation — however good — is a commodity Google gives away. A first run
/// should demonstrate the thing that has no equivalent.
///
/// One try-it, not two. It teaches the hotkey and the capture in the same
/// gesture, which is the "teach by hands" rule holding: you cannot point at
/// something and speak without also learning to hold the key.
struct OnboardingView: View {
    let onDone: () -> Void
    @Environment(SessionManager.self) private var session

    private enum Step: Int, CaseIterable {
        case welcome
        case setup
        case capture
        case connect
        case done

        var analyticsName: String {
            switch self {
            case .welcome: "welcome"
            case .setup: "setup"
            case .tryIt: "tryIt"
            case .done: "done"
            }
        }
    }

    @State private var step: Step = .welcome
    /// Furthest step reached, so the funnel signal fires once per step —
    /// revisiting a passed step via the dots is not progress.
    @State private var furthestStep: Step = .welcome
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
    /// Capture count on entering the try-it, so "did they make one" is a
    /// comparison rather than a guess.
    @State private var capturesBefore = 0
    @State private var connecting = false
    @ObservedObject private var linear = LinearSettings.shared

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
            case .capture: capture
            case .connect: connect
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
        .onAppear {
            Telemetry.send(.onboardingStep, ["step": Step.welcome.analyticsName])
        }
        .onChange(of: step) {
            guard step.rawValue > furthestStep.rawValue else { return }
            furthestStep = step
            Telemetry.send(.onboardingStep, ["step": step.analyticsName])
        }
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
    // teaches the keys with your hands already on them. Mechanics before
    // motivation read as homework.
    private var welcome: some View {
        stepLayout(
            icon: { logo },
            title: "Say what's wrong. Get a ticket.",
            lines: [
                "Point at the thing, hold a key, and describe it.",
                "Yorick writes it up with what you were looking at — and none of it leaves your Mac unless you send it."
            ]
        ) {
            primaryButton("Continue") { step = .setup }
        }
    }

    // MARK: Capture try-it
    //
    // NOTHING here is simulated. The real pill, the real pointer sweep, the
    // real context bundle — and the capture the user makes is their genuine
    // first saved item, waiting in the list afterwards. A demo that fakes its
    // own product teaches the wrong thing twice: once about the mechanic, and
    // once about whether to trust what it shows you.

    private var capture: some View {
        stepLayout(
            icon: { EmptyView() },
            title: "Point at something and say what's wrong",
            lines: []
        ) {
            HStack(spacing: 6) {
                Text("Hover the mess below, hold")
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.textSecondary)
                HotkeyChips()
                Text("and say what you'd change.")
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            // The keyboard map and the rebind link move here with the
            // hotkey's first teaching. Losing them would be a regression, not
            // a simplification: the map lights held keys purple and wrong
            // ones red (hands, not prose), and the quiet rebind link is the
            // only recovery when another app already owns the combo — ⌥Space
            // is Raycast's default, and Handy's, which otherwise looks
            // exactly like "Yorick is broken."
            KeyboardMapView(
                targetKeyCodes: ShortcutLabel.targetKeyCodes,
                comboActive: session.state == .recording
            )
            .id(shortcutGeneration)
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
            practiceTarget
            if let made = session.lastSavedCapture ?? firstCapture {
                capturedProof(made)
            } else {
                Text("Yorick notes what you pointed at, not just what you said.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            }
            primaryButton(firstCapture == nil ? "Skip for now" : "Continue") {
                step = .connect
            }
        }
        .onAppear {
            // The practice target lives inside Yorick's own window, so the
            // self-evidence rule has to stand down for exactly this step.
            ContextCollector.selfEvidenceAllowed = true
            capturesBefore = session.captureStore.captures.count
        }
        .onDisappear { ContextCollector.selfEvidenceAllowed = false }
    }

    /// A deliberately terrible little interface. Terrible on purpose: the
    /// instruction is "say what you'd change", and a good design gives nobody
    /// anything to say.
    private var practiceTarget: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SYNERGY DASHBOARD PRO!!")
                .font(.system(size: 21, weight: .black))
                .foregroundStyle(Color(red: 0.95, green: 0.35, blue: 0.55))
            Text("Q3 Metrics")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 10) {
                ForEach(["Revenue 412%", "Synergy 88", "Blockers 3"], id: \.self) { chip in
                    Text(chip)
                        .font(.system(size: 11))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Text("click here to maybe continue →")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.95))
                .underline()
        }
        .padding(18)
        .frame(width: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    /// What it built, shown back. This is the whole pitch in one panel, and
    /// it is the user's own words about their own gesture — never a sample.
    private func capturedProof(_ made: Capture) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(TitleComposer.deterministicTitle(IssueComposer.Input(made)))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            ForEach(LinearDescriptionBuilder.contextLines(
                made.context, windowTitle: made.windowTitle
            ), id: \.self) { line in
                Text(line)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(width: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bgCard))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.glow.opacity(0.35), lineWidth: 1))
        .transition(.opacity)
    }

    /// The capture the user just made, if they made one.
    private var firstCapture: Capture? {
        let captures = session.captureStore.captures
        guard captures.count > capturesBefore else { return nil }
        return captures.sorted { $0.timestamp > $1.timestamp }.first
    }

    // MARK: Connect
    //
    // SKIPPABLE, and the skip is a real answer rather than a deferral: Copy
    // ticket produces the same artifact with nothing set up. A product whose
    // point is filing tickets can't hide the filing — but it also shouldn't
    // hold the door shut until you sign in to something.

    private var connect: some View {
        stepLayout(
            icon: { EmptyView() },
            title: "Where should tickets go?",
            lines: ["You can change this later, or never."]
        ) {
            VStack(spacing: 10) {
                setupRow(
                    icon: "arrow.up.forward.app",
                    name: "Linear",
                    why: linear.isConnected
                        ? "Connected. Captures can be filed straight into your workspace."
                        : "File captures as issues, with the context attached. Opens your browser once.",
                    granted: linear.isConnected,
                    actionLabel: connecting ? "Connecting…" : "Connect"
                ) {
                    connecting = true
                    Task {
                        await LinearSendController.shared.connect()
                        connecting = false
                    }
                }
                setupRow(
                    icon: "doc.on.clipboard",
                    name: "Anywhere else",
                    why: "Copy ticket puts the whole thing — title, words, context, screenshot — on your clipboard. Paste it into an agent, an issue, a message.",
                    granted: true,
                    actionLabel: ""
                ) {}
            }
            .frame(width: 500)
            primaryButton(linear.isConnected ? "Continue" : "Continue without connecting") {
                step = .done
            }
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
            lines: ["Everything runs on your Mac. Nothing is uploaded unless you send it."]
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
                    // Names screen reading up front now. Under the old
                    // positioning that was preemptive noise for the majority
                    // who never enabled capture; under this one it IS the
                    // product, and burying it would be the privacy surprise
                    // the 2026-07-29 removal was written to avoid.
                    why: "Reads what you point at, and types into the app you're using.",
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
            primaryButton("Continue") { step = .capture }
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

    private var done: some View {
        stepLayout(
            icon: { logo },
            title: "One more thing",
            lines: [
                "Hold the same key with your cursor in a text field, and your words are typed there instead.",
                "Same gesture. Yorick works out where they should go.",
                "Yorick sends anonymous usage counts, never your words. You can turn this off in Settings."
            ]
        ) {
            practiceField
            Text("Yorick lives in your menu bar. This window closes; everything else stays.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
            primaryButton("Start using Yorick") {
                Telemetry.send(.onboardingCompleted)
                onDone()
            }
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
            Image("SkullLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
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
