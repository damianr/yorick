import AppKit

/// Drag-to-frame region selection, drawn by Yorick.
///
/// REPLACES `screencapture -i`, which was the right first call and the wrong
/// one here. The system crosshair reads modifier keys — Option means "resize
/// from the center" — and Yorick's recording is push-to-talk, so ⌥Space is
/// necessarily HELD while you frame the shot. Every drag came out
/// center-anchored, and no flag turns that off: the conflict is structural,
/// not a setting. Owning the overlay is the only way to get the anchor right,
/// and it removes the subprocess besides.
///
/// The anchor rule is the ordinary one: the mouse-down point is a corner and
/// stays put; the rect grows toward wherever you drag. Drag up-left from a
/// low-right click and the bottom-right corner is pinned. Modifiers are
/// ignored on purpose — the hotkey is holding some of them down.
@MainActor
final class RegionSelector {
    private var window: NSWindow?
    private var continuation: CheckedContinuation<CGRect?, Never>?

    /// Show the overlay and wait. Returns the chosen rect in TOP-LEFT screen
    /// coordinates (what CoreGraphics and ScreenCaptureKit want), or nil if
    /// the user cancelled.
    func selectRegion() async -> CGRect? {
        // One window spanning the union of every screen, rather than one per
        // display: a drag that starts on one monitor and ends on another is
        // then just a drag, with no cross-window event handoff to get wrong.
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !union.isNull else { return nil }

        let view = SelectionView(frame: CGRect(origin: .zero, size: union.size))
        let panel = NSPanel(
            contentRect: union,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above everything including other floating panels, so the pill
        // itself can't sit on top of the region you're trying to frame.
        panel.level = .screenSaver
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        window = panel

        view.onFinish = { [weak self] rect in
            Task { @MainActor in self?.finish(rect) }
        }

        panel.makeKeyAndOrderFront(nil)
        // A borderless panel needs to be key to receive Escape; activating is
        // acceptable here because the user just clicked a button and expects
        // to be doing something.
        NSApp.activate(ignoringOtherApps: true)
        view.beginTracking()

        let selected = await withCheckedContinuation { (continuation: CheckedContinuation<CGRect?, Never>) in
            self.continuation = continuation
        }
        guard let selected, selected.width >= 4, selected.height >= 4 else { return nil }

        // AppKit hands us bottom-left origin coordinates; CoreGraphics and
        // ScreenCaptureKit want top-left, measured from the PRIMARY screen.
        // Getting this backwards silently captures a mirrored band of screen,
        // which looks like a capture bug rather than a maths one.
        guard let primary = NSScreen.screens.first else { return nil }
        let flippedY = primary.frame.maxY - selected.maxY
        return CGRect(x: selected.minX, y: flippedY, width: selected.width, height: selected.height)
    }

    private func finish(_ rect: CGRect?) {
        window?.orderOut(nil)
        window = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: rect)
    }
}

/// The dimmed backdrop with a clear hole, and the drag maths.
private final class SelectionView: NSView {
    /// Called once with the chosen rect in SCREEN coordinates, or nil on
    /// cancel. The selector orders the window out before capturing, so the
    /// overlay can never appear in the shot.
    var onFinish: ((CGRect?) -> Void)?

    private var anchor: CGPoint?
    private var current: CGPoint?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    func beginTracking() {
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
        // A local monitor catches Escape even if first-responder status
        // wobbles on a borderless panel — the cancel path has to be certain.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Escape
            self?.cancel()
            return nil
        }
    }

    private func stopTracking() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NSCursor.arrow.set()
    }

    private func cancel() {
        stopTracking()
        onFinish?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        // The mouse-down point is the ANCHOR corner and never moves. This is
        // the whole reason this view exists.
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        stopTracking()
        guard let rect = selectionRect, let window else {
            onFinish?(nil)
            return
        }
        onFinish?(window.convertToScreen(convert(rect, to: nil)))
    }

    /// Right-click cancels, matching the system crosshair's habit.
    override func rightMouseDown(with event: NSEvent) { cancel() }

    override func cancelOperation(_ sender: Any?) { cancel() }

    /// Normalized so the rect is valid whichever way the drag went — the
    /// anchor is a corner, not necessarily the origin.
    private var selectionRect: CGRect? {
        guard let anchor, let current else { return nil }
        return CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        guard let rect = selectionRect, rect.width > 0, rect.height > 0 else { return }
        // Punch the selection clear so you're framing the real pixels, not a
        // dimmed guess at them.
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        // Bone, because it's the app's live-state colour and reads on any
        // backdrop — the same reason the pill's rim is bone.
        NSColor(red: 0.925, green: 0.898, blue: 0.847, alpha: 0.95).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        // Above the rect normally, inside it when the selection is jammed
        // against the top of the screen.
        let labelY = rect.maxY + 6 + size.height > bounds.maxY ? rect.maxY - size.height - 6 : rect.maxY + 6
        let origin = CGPoint(x: rect.minX, y: labelY)
        let backdrop = CGRect(origin: origin, size: size).insetBy(dx: -5, dy: -3)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: backdrop, xRadius: 4, yRadius: 4).fill()
        label.draw(at: origin, withAttributes: attributes)
    }
}
