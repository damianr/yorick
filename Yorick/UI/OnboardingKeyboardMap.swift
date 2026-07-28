import AppKit
import SwiftUI

/// A compact keyboard with the hotkey's keys highlighted, and LIVE press
/// feedback: right keys light purple as you hold them, wrong keys flash
/// red. Teaching by hands, not by prose — the map answers "which keys?"
/// at a glance and "am I doing it?" in real time.
struct KeyboardMapView: View {
    let targetKeyCodes: Set<UInt16>
    /// True while the session is recording — proof the WHOLE combo is held.
    /// Needed because the global hotkey consumes the final key's event
    /// before the local monitor sees it (modifiers still arrive as flag
    /// changes, so option lit while space never did).
    var comboActive: Bool = false

    @State private var pressedKeys: Set<UInt16> = []
    @State private var pressedModifierCodes: Set<UInt16> = []
    @State private var monitor: Any?

    private struct Key: Identifiable {
        let code: UInt16
        let label: String
        var width: CGFloat = 1
        var id: String { "\(code)-\(label)" }
    }

    private static let rows: [[Key]] = [
        [Key(code: 50, label: "`"), Key(code: 18, label: "1"), Key(code: 19, label: "2"),
         Key(code: 20, label: "3"), Key(code: 21, label: "4"), Key(code: 23, label: "5"),
         Key(code: 22, label: "6"), Key(code: 26, label: "7"), Key(code: 28, label: "8"),
         Key(code: 25, label: "9"), Key(code: 29, label: "0"), Key(code: 27, label: "-"),
         Key(code: 24, label: "="), Key(code: 51, label: "⌫", width: 1.5)],
        [Key(code: 48, label: "⇥", width: 1.5), Key(code: 12, label: "Q"), Key(code: 13, label: "W"),
         Key(code: 14, label: "E"), Key(code: 15, label: "R"), Key(code: 17, label: "T"),
         Key(code: 16, label: "Y"), Key(code: 32, label: "U"), Key(code: 34, label: "I"),
         Key(code: 31, label: "O"), Key(code: 35, label: "P"), Key(code: 33, label: "["),
         Key(code: 30, label: "]"), Key(code: 42, label: "\\")],
        [Key(code: 57, label: "⇪", width: 1.8), Key(code: 0, label: "A"), Key(code: 1, label: "S"),
         Key(code: 2, label: "D"), Key(code: 3, label: "F"), Key(code: 5, label: "G"),
         Key(code: 4, label: "H"), Key(code: 38, label: "J"), Key(code: 40, label: "K"),
         Key(code: 37, label: "L"), Key(code: 41, label: ";"), Key(code: 39, label: "'"),
         Key(code: 36, label: "↩", width: 1.7)],
        [Key(code: 56, label: "⇧", width: 2.3), Key(code: 6, label: "Z"), Key(code: 7, label: "X"),
         Key(code: 8, label: "C"), Key(code: 9, label: "V"), Key(code: 11, label: "B"),
         Key(code: 45, label: "N"), Key(code: 46, label: "M"), Key(code: 43, label: ","),
         Key(code: 47, label: "."), Key(code: 44, label: "/"), Key(code: 60, label: "⇧", width: 2.2)],
        [Key(code: 59, label: "⌃", width: 1.3), Key(code: 58, label: "⌥", width: 1.3),
         Key(code: 55, label: "⌘", width: 1.6), Key(code: 49, label: "", width: 4.9),
         Key(code: 54, label: "⌘", width: 1.6), Key(code: 61, label: "⌥", width: 1.3),
         Key(code: 62, label: "⌃", width: 1.3)],
    ]

    private let unit: CGFloat = 21
    private let keyHeight: CGFloat = 16
    private let gap: CGFloat = 2.5

    var body: some View {
        VStack(spacing: gap) {
            ForEach(0..<Self.rows.count, id: \.self) { rowIndex in
                HStack(spacing: gap) {
                    ForEach(Self.rows[rowIndex]) { key in
                        keycap(key)
                    }
                }
            }
        }
        .onAppear(perform: installMonitor)
        .onDisappear(perform: removeMonitor)
        .animation(.easeOut(duration: 0.1), value: pressedKeys)
        .animation(.easeOut(duration: 0.1), value: pressedModifierCodes)
        .animation(.easeOut(duration: 0.1), value: comboActive)
    }

    private func keycap(_ key: Key) -> some View {
        let isTarget = targetKeyCodes.contains(key.code)
        let isPressed = pressedKeys.contains(key.code)
            || pressedModifierCodes.contains(key.code)
            || (comboActive && isTarget)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(fillColor(target: isTarget, pressed: isPressed))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        isTarget ? Theme.accentPurple.opacity(isPressed ? 0 : 0.8) : Color.white.opacity(0.06),
                        lineWidth: 1
                    )
            )
            .overlay(
                Text(key.label)
                    .font(.system(size: 7.5, weight: .medium))
                    .foregroundStyle(labelColor(target: isTarget, pressed: isPressed))
            )
            .frame(width: unit * key.width + gap * (key.width - 1), height: keyHeight)
    }

    private func fillColor(target: Bool, pressed: Bool) -> Color {
        switch (target, pressed) {
        case (true, true): return Theme.accentPurple
        case (true, false): return Theme.accentPurple.opacity(0.10)
        case (false, true): return Color.red.opacity(0.75)
        case (false, false): return Theme.bgElevated
        }
    }

    private func labelColor(target: Bool, pressed: Bool) -> Color {
        switch (target, pressed) {
        case (true, true): return .black.opacity(0.8)
        case (false, true): return .white
        case (true, false): return Theme.accentPurple
        case (false, false): return Theme.textTertiary
        }
    }

    // MARK: - Live key monitoring (local: the onboarding window is frontmost)

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            switch event.type {
            case .keyDown: pressedKeys.insert(event.keyCode)
            case .keyUp: pressedKeys.remove(event.keyCode)
            case .flagsChanged:
                var codes: Set<UInt16> = []
                let flags = event.modifierFlags
                if flags.contains(.control) { codes.formUnion([59, 62]) }
                if flags.contains(.option) { codes.formUnion([58, 61]) }
                if flags.contains(.shift) { codes.formUnion([56, 60]) }
                if flags.contains(.command) { codes.formUnion([55, 54]) }
                pressedModifierCodes = codes
            default: break
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pressedKeys = []
        pressedModifierCodes = []
    }
}
