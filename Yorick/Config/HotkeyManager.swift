import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // Option + ` (backtick): minimal interference with mouse/scroll during recording.
    static let toggleSession = Self("toggleSession", default: .init(.backtick, modifiers: [.option]))
}

@MainActor
enum HotkeyManager {
    /// Single push-to-talk hotkey. Hold to record, release to stop.
    static func registerAll(
        onKeyDown: @escaping () -> Void,
        onKeyUp: @escaping () -> Void
    ) {
        KeyboardShortcuts.removeAllHandlers()

        // Migrate from old shortcut: if the stored shortcut is the old ⌥⇧S,
        // reset to the new default (⌥`)
        if let current = KeyboardShortcuts.getShortcut(for: .toggleSession),
           current.key == .s && current.modifiers == [.option, .shift] {
            KeyboardShortcuts.reset(.toggleSession)
            print("[HotkeyManager] Migrated from old ⌥⇧S to new default")
        }

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleSession)
        print("[HotkeyManager] Registering shortcut: \(String(describing: shortcut))")
        KeyboardShortcuts.onKeyDown(for: .toggleSession) { onKeyDown() }
        KeyboardShortcuts.onKeyUp(for: .toggleSession) { onKeyUp() }
    }
}
