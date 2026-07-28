import SwiftUI
import KeyboardShortcuts
import Carbon.HIToolbox

/// Custom shortcut recorder that works in NavigationStack destinations.
///
/// The library's built-in `KeyboardShortcuts.Recorder` uses `NSEvent.addLocalMonitorForEvents`
/// with first-responder management that breaks when hosted inside a NavigationStack push.
/// This view uses its own local event monitor and captures keys regardless of responder chain.
struct ShortcutRecorderView: View {
    let name: KeyboardShortcuts.Name
    var label = "Hotkey"
    /// Onboarding style: instruction + Record only. No current-keys readout
    /// (the chips and keyboard highlights are the confirmation) and no
    /// Clear (onboarding must never leave the app hotkey-less).
    var compact = false

    @State private var isRecording = false
    @State private var currentShortcut: KeyboardShortcuts.Shortcut?
    @State private var monitor: Any?

    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
    }

    private var compactBody: some View {
        HStack(spacing: 10) {
            if isRecording {
                Text("Press your key combination…")
                    .font(Theme.mono(10))
                    .italic()
                    .foregroundStyle(Theme.bone)
                Button("Cancel") { stopRecording() }
                    .buttonStyle(.plain)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("Click record, then press your keys.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                Button { startRecording() } label: {
                    Text("Record")
                        .font(Theme.mono(10, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { currentShortcut = KeyboardShortcuts.getShortcut(for: name) }
        .onDisappear { stopRecording() }
    }

    private var fullBody: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                if isRecording {
                    Text("Press shortcut…")
                        .foregroundStyle(.secondary)
                        .italic()
                } else if let shortcut = currentShortcut {
                    Text(shortcutLabel(shortcut))
                        .monospacedDigit()
                } else {
                    Text("Not set")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isRecording {
                    Button("Cancel") {
                        stopRecording()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                } else {
                    Button("Record") {
                        startRecording()
                    }
                    .font(.caption)

                    if currentShortcut != nil {
                        Button("Clear") {
                            KeyboardShortcuts.setShortcut(nil, for: name)
                            currentShortcut = nil
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }
                }
            }
        }
        .onAppear {
            currentShortcut = KeyboardShortcuts.getShortcut(for: name)
        }
        .onDisappear {
            stopRecording()
        }
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true

        // Use both local (for when app is focused) and global (for system-wide capture)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [self] event in
            handleKeyEvent(event)
            return nil // consume the event
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Escape cancels recording
        if event.keyCode == UInt16(kVK_Escape) && modifiers.isEmpty {
            stopRecording()
            return
        }

        // Require at least one modifier key (Cmd, Option, Control, Shift)
        let hasModifier = modifiers.contains(.command) ||
                          modifiers.contains(.option) ||
                          modifiers.contains(.control)

        // Allow Shift only with another modifier or a function key
        guard hasModifier || event.keyCode >= 0x60 else {
            NSSound.beep()
            return
        }

        // Create and save the shortcut
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            NSSound.beep()
            return
        }

        KeyboardShortcuts.setShortcut(shortcut, for: name)
        currentShortcut = shortcut
        stopRecording()
    }

    // MARK: - Display

    private func shortcutLabel(_ shortcut: KeyboardShortcuts.Shortcut) -> String {
        var parts: [String] = []
        let mods = NSEvent.ModifierFlags(carbonFlags: shortcut.carbonModifiers)

        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option)  { parts.append("⌥") }
        if mods.contains(.shift)   { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }

        if let key = shortcut.key {
            parts.append(keyName(key))
        }

        return parts.joined()
    }

    private func keyName(_ key: KeyboardShortcuts.Key) -> String {
        // Map common key codes to display names
        let code = key.rawValue
        switch code {
        case Int(kVK_Return):       return "↩"
        case Int(kVK_Tab):          return "⇥"
        case Int(kVK_Space):        return "Space"
        case Int(kVK_Delete):       return "⌫"
        case Int(kVK_ForwardDelete): return "⌦"
        case Int(kVK_UpArrow):      return "↑"
        case Int(kVK_DownArrow):    return "↓"
        case Int(kVK_LeftArrow):    return "←"
        case Int(kVK_RightArrow):   return "→"
        case Int(kVK_ANSI_A): return "A"
        case Int(kVK_ANSI_S): return "S"
        case Int(kVK_ANSI_D): return "D"
        case Int(kVK_ANSI_F): return "F"
        case Int(kVK_ANSI_G): return "G"
        case Int(kVK_ANSI_H): return "H"
        case Int(kVK_ANSI_J): return "J"
        case Int(kVK_ANSI_K): return "K"
        case Int(kVK_ANSI_L): return "L"
        case Int(kVK_ANSI_Q): return "Q"
        case Int(kVK_ANSI_W): return "W"
        case Int(kVK_ANSI_E): return "E"
        case Int(kVK_ANSI_R): return "R"
        case Int(kVK_ANSI_T): return "T"
        case Int(kVK_ANSI_Y): return "Y"
        case Int(kVK_ANSI_U): return "U"
        case Int(kVK_ANSI_I): return "I"
        case Int(kVK_ANSI_O): return "O"
        case Int(kVK_ANSI_P): return "P"
        case Int(kVK_ANSI_Z): return "Z"
        case Int(kVK_ANSI_X): return "X"
        case Int(kVK_ANSI_C): return "C"
        case Int(kVK_ANSI_V): return "V"
        case Int(kVK_ANSI_B): return "B"
        case Int(kVK_ANSI_N): return "N"
        case Int(kVK_ANSI_M): return "M"
        case Int(kVK_ANSI_0): return "0"
        case Int(kVK_ANSI_1): return "1"
        case Int(kVK_ANSI_2): return "2"
        case Int(kVK_ANSI_3): return "3"
        case Int(kVK_ANSI_4): return "4"
        case Int(kVK_ANSI_5): return "5"
        case Int(kVK_ANSI_6): return "6"
        case Int(kVK_ANSI_7): return "7"
        case Int(kVK_ANSI_8): return "8"
        case Int(kVK_ANSI_9): return "9"
        case Int(kVK_F1): return "F1"
        case Int(kVK_F2): return "F2"
        case Int(kVK_F3): return "F3"
        case Int(kVK_F4): return "F4"
        case Int(kVK_F5): return "F5"
        case Int(kVK_F6): return "F6"
        case Int(kVK_F7): return "F7"
        case Int(kVK_F8): return "F8"
        case Int(kVK_F9): return "F9"
        case Int(kVK_F10): return "F10"
        case Int(kVK_F11): return "F11"
        case Int(kVK_F12): return "F12"
        case Int(kVK_F13): return "F13"
        case Int(kVK_F14): return "F14"
        case Int(kVK_F15): return "F15"
        case Int(kVK_F16): return "F16"
        case Int(kVK_F17): return "F17"
        case Int(kVK_F18): return "F18"
        case Int(kVK_F19): return "F19"
        case Int(kVK_F20): return "F20"
        default: return String(format: "Key%d", code)
        }
    }
}

// MARK: - NSEvent.ModifierFlags ↔ Carbon

private extension NSEvent.ModifierFlags {
    init(carbonFlags: Int) {
        self.init()
        if carbonFlags & cmdKey != 0    { insert(.command) }
        if carbonFlags & optionKey != 0 { insert(.option) }
        if carbonFlags & controlKey != 0 { insert(.control) }
        if carbonFlags & shiftKey != 0  { insert(.shift) }
    }
}
