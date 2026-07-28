import AppKit

/// Where the unanchored (observation) pill and card live — a user setting
/// (Preferences → "Saved-note position"), top-center by default.
enum HUDPlacement {
    static let unanchoredAtTopKey = "unanchoredPillAtTop"
    static var unanchoredAtTop: Bool {
        UserDefaults.standard.object(forKey: unanchoredAtTopKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: unanchoredAtTopKey)
    }
}
import SwiftUI

final class HUDWindow: NSPanel {
    init(sessionManager: SessionManager) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        let hostingView = NSHostingView(
            rootView: HUDContentView()
                .environment(sessionManager)
        )
        hostingView.frame = contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        contentView?.addSubview(hostingView)

        positionUnanchored()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // SessionManager anchors the pill next to the focused field during
        // dictation; no origin in userInfo means "go home to bottom-center".
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionRequested(_:)),
            name: .hudReposition,
            object: nil
        )
    }

    @objc private func repositionRequested(_ note: Notification) {
        if let value = note.userInfo?["origin"] as? NSValue {
            setFrameOrigin(value.pointValue)
        } else {
            positionUnanchored()
        }
    }

    func positionUnanchored() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - (frame.width / 2)
        let y = HUDPlacement.unanchoredAtTop
            ? screenFrame.maxY - frame.height - 40
            : screenFrame.minY + 40
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func screenDidChange() {
        positionUnanchored()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Don't let AppKit drag the panel back on-screen. We position this oversized
    /// transparent window precisely so the pill (pinned to one edge) lands at the
    /// caret; when the caret is near the top or bottom of the screen the window's
    /// far edge legitimately hangs past the screen. AppKit's default constraint
    /// shoved the whole window — and the pill with it — back inside, which is what
    /// made the pill sit "low" for first-line carets. The pill edge itself always
    /// stays on-screen (it's at the on-screen caret), so this is safe.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
