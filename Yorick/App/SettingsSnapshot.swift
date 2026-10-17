#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: renders the Settings page to PNGs and quits, so a change to
/// Settings can be shown as before/after images without Screen Recording
/// permission. `YORICK_SNAPSHOT_SETTINGS=/dir open Yorick.app` writes
/// settings-fold.png (what the panel shows before scrolling) and
/// settings-full.png (the whole page).
@MainActor
enum SettingsSnapshot {
    static func runIfRequested(session: SessionManager) -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["YORICK_SNAPSHOT_SETTINGS"] else { return false }
        let out = URL(fileURLWithPath: dir)
        // Let observers (mic list, permissions) settle before drawing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            render(session: session, height: 515, to: out.appendingPathComponent("settings-fold.png"))
            render(session: session, height: 1900, to: out.appendingPathComponent("settings-full.png"))
            exit(0)
        }
        return true
    }

    private static func render(session: SessionManager, height: CGFloat, to url: URL) {
        let root = SettingsView(session: session)
            .environment(session)
            .frame(width: 420, height: height)
            .background(Color(white: 0.06))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
#endif
