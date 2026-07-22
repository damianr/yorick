import AppKit
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

        positionAtBottomCenter()

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
            positionAtBottomCenter()
        }
    }

    func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowWidth = frame.width
        let x = screenFrame.midX - (windowWidth / 2)
        let y = screenFrame.minY + 40
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func screenDidChange() {
        positionAtBottomCenter()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
