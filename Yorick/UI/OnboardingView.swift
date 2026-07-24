import SwiftUI
import AVFoundation
import ApplicationServices

/// First-run flow: what Yorick does, the two permissions it needs, and a
/// ten-second first dictation. Zero configuration by design — no accounts,
/// no keys, no downloads on the default path.
struct OnboardingView: View {
    let onDone: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome
        case microphone
        case accessibility
        case tryIt
    }

    @State private var step: Step = .welcome
    @State private var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var practiceText = ""
    @FocusState private var practiceFocused: Bool

    private let axPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            switch step {
            case .welcome: welcome
            case .microphone: microphone
            case .accessibility: accessibility
            case .tryIt: tryIt
            }

            Spacer()

            // Progress dots
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? Theme.accentPurple : Theme.bgElevated)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPrimary)
        .onReceive(axPoll) { _ in
            // Granting Accessibility happens in System Settings — poll so the
            // step advances the moment the toggle flips, no relaunch needed.
            accessibilityTrusted = AXIsProcessTrusted()
            microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        stepLayout(
            icon: { logo },
            title: "Talk instead of type",
            lines: [
                "Hold  ⌥`  and speak. Release to finish.",
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
            } else {
                primaryButton("Allow Microphone Access") {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async {
                            microphoneGranted = granted
                            if granted { step = .accessibility }
                        }
                    }
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
                primaryButton("Continue") { step = .tryIt }
            } else {
                primaryButton("Open Accessibility Settings") {
                    let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
                    AXIsProcessTrustedWithOptions(options)
                }
                quietButton("Skip for now — dictation won't type until enabled") {
                    step = .tryIt
                }
            }
        }
    }

    private var tryIt: some View {
        stepLayout(
            icon: { logo },
            title: "Try it here",
            lines: [
                "Click the box, hold  ⌥`  , say a sentence, release."
            ]
        ) {
            practiceField
            if practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("It works the same in every app. No text field focused? Your words are saved to this window instead.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            } else {
                grantedLabel("That's it. That's the whole app.")
            }
            primaryButton("Start using Yorick") { onDone() }
            Text("Yorick lives in your menu bar. This window is your saved list.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
        }
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
