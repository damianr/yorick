import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // Option + Space: the de facto default for local dictation tools (Handy,
    // Superwhisper both ship it), so it's what users reach for first. Held, not
    // tapped, so it doesn't collide with the OS input-source switcher.
    static let toggleSession = Self("toggleSession", default: .init(.space, modifiers: [.option]))
}

/// How the trigger is written for humans. `symbols` is the compact glyph form
/// ("⌥Space"); `spelled` names the modifiers in words ("Option and Space"),
/// because ⌥ ⌘ ⌃ are jargon to plenty of people and onboarding shouldn't assume.
@MainActor
enum ShortcutLabel {
    static var symbols: String {
        KeyboardShortcuts.getShortcut(for: .toggleSession)
            .map(String.init(describing:)) ?? "⌥Space"
    }

    /// The shortcut as chips: one per key, symbol plus short name — "⌥ OPT"
    /// + "SPACE" — so nobody has to decode glyphs from a prose aside.
    static var chips: [String] {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .toggleSession) else {
            return ["⌥ OPT", "SPACE"]
        }
        var chips: [String] = []
        let mods = shortcut.modifiers
        if mods.contains(.control) { chips.append("⌃ CTRL") }
        if mods.contains(.option) { chips.append("⌥ OPT") }
        if mods.contains(.shift) { chips.append("⇧ SHIFT") }
        if mods.contains(.command) { chips.append("⌘ CMD") }

        var key = String(describing: shortcut)
        for glyph in ["⌃", "⌥", "⇧", "⌘"] { key = key.replacingOccurrences(of: glyph, with: "") }
        key = key.trimmingCharacters(in: .whitespaces)
        let spelledSymbols: [String: String] = [
            "`": "` TILDE", ",": ", COMMA", ".": ". PERIOD", "/": "/ SLASH",
            ";": "; SEMI", "'": "' QUOTE", "-": "- MINUS", "=": "= EQUALS",
            "[": "[ BRACKET", "]": "] BRACKET", "\\": "\\ BACKSLASH",
        ]
        if !key.isEmpty {
            chips.append(spelledSymbols[key] ?? key.uppercased())
        }
        return chips
    }

    /// Physical key codes the current shortcut wants pressed — both sides
    /// for modifiers — for the onboarding keyboard map's highlights.
    static var targetKeyCodes: Set<UInt16> {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .toggleSession) else {
            return [58, 61, 49] // option (both) + space
        }
        var codes: Set<UInt16> = []
        let mods = shortcut.modifiers
        if mods.contains(.control) { codes.formUnion([59, 62]) }
        if mods.contains(.option) { codes.formUnion([58, 61]) }
        if mods.contains(.shift) { codes.formUnion([56, 60]) }
        if mods.contains(.command) { codes.formUnion([55, 54]) }
        if let key = shortcut.key { codes.insert(UInt16(key.rawValue)) }
        return codes
    }

    static var spelled: String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .toggleSession) else {
            return "Option and Space"
        }
        let mods = shortcut.modifiers
        var words: [String] = []
        if mods.contains(.control) { words.append("Control") }
        if mods.contains(.option) { words.append("Option") }
        if mods.contains(.shift) { words.append("Shift") }
        if mods.contains(.command) { words.append("Command") }

        // Strip the modifier glyphs off the description; what remains is the key
        // name, which avoids maintaining a table of every key.
        var key = String(describing: shortcut)
        for glyph in ["⌃", "⌥", "⇧", "⌘"] { key = key.replacingOccurrences(of: glyph, with: "") }
        key = key.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { words.append(key) }

        switch words.count {
        case 0: return "Option and Space"
        case 1: return words[0]
        default: return words.dropLast().joined(separator: " and ") + " and " + words.last!
        }
    }
}

@MainActor
enum HotkeyManager {
    /// Single push-to-talk hotkey. Hold to record, release to stop.
    static func registerAll(
        onKeyDown: @escaping () -> Void,
        onKeyUp: @escaping () -> Void
    ) {
        KeyboardShortcuts.removeAllHandlers()

        // Move anyone still sitting on a superseded default (⌥⇧S, then ⌥`) onto
        // the current one — ONCE, ever. This used to run on every launch, which
        // silently re-stole the shortcut from anyone who had deliberately CHOSEN
        // ⌥` : their pick is indistinguishable from a stale default, so it got
        // reset on each update. The flag makes it a one-time migration; from then
        // on the user's choice is the user's choice.
        let migrationKey = "didMigrateShortcutDefaultToOptionSpace"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            UserDefaults.standard.set(true, forKey: migrationKey)
            if let current = KeyboardShortcuts.getShortcut(for: .toggleSession),
               (current.key == .s && current.modifiers == [.option, .shift])
                || (current.key == .backtick && current.modifiers == [.option]) {
                KeyboardShortcuts.reset(.toggleSession)
                print("[HotkeyManager] One-time migration of superseded default to ⌥Space")
            }
        }

        let shortcut = KeyboardShortcuts.getShortcut(for: .toggleSession)
        print("[HotkeyManager] Registering shortcut: \(String(describing: shortcut))")
        KeyboardShortcuts.onKeyDown(for: .toggleSession) { onKeyDown() }
        KeyboardShortcuts.onKeyUp(for: .toggleSession) { onKeyUp() }
    }
}
