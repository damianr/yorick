import SwiftUI
import KeyboardShortcuts

/// Chips for the current hotkey: "⌥ OPT" + "SPACE". Shared by onboarding's
/// try-it instruction and the settings hotkey editor.
struct HotkeyChips: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(ShortcutLabel.chips.enumerated()), id: \.offset) { index, chip in
                if index > 0 {
                    Text("+")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(chip)
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.bgElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
                    )
            }
        }
    }
}

/// The shortcut recorder dressed as one of ours: pill container, explicit
/// dismiss. Auto-hiding on a successful rebind is the CALLER's job (watch
/// the KeyboardShortcuts change notification) — the chips and keyboard
/// re-highlighting are the confirmation.
struct CompactRecorderPill: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ShortcutRecorderView(name: .toggleSession, label: "", compact: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.bgElevated))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

/// The onboarding try-it's teach-by-hands hotkey block, reused in settings:
/// chips naming the combo, the live keyboard map that lights the keys as
/// they're held, and rebinding demoted to a quiet link that reveals the
/// compact recorder.
struct HotkeyEditorView: View {
    @Environment(SessionManager.self) private var session
    @State private var showRecorder = false
    /// Bumped when the shortcut is rebound — recording a new combo changes
    /// no SwiftUI state, so chips and keyboard highlights went stale.
    @State private var generation = 0

    var body: some View {
        VStack(spacing: 10) {
            HotkeyChips()
                .id(generation)
            // `comboActive`: recording in progress means the full combo is
            // down (the hotkey machinery eats the final key's event, so the
            // monitor alone can never see the whole chord).
            KeyboardMapView(
                targetKeyCodes: ShortcutLabel.targetKeyCodes,
                comboActive: session.state == .recording
            )
            .id(generation)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showRecorder.toggle() }
            } label: {
                Text("Set your own key combination")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .underline()
            }
            .buttonStyle(.plain)
            if showRecorder {
                CompactRecorderPill {
                    withAnimation(.easeOut(duration: 0.15)) { showRecorder = false }
                }
            }
        }
        .frame(maxWidth: .infinity)
        // KeyboardShortcuts' change notification (raw name; the library
        // doesn't export a constant) — re-render on rebind, and the
        // recorder's job is done the moment a combo lands.
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
        )) { _ in
            generation += 1
            withAnimation(.easeOut(duration: 0.2)) { showRecorder = false }
        }
    }
}
