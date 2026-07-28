import AppKit
import SwiftUI

/// The menu bar panel — Yorick's primary surface on the road to being a
/// conduit, not a workspace. A custom NSStatusItem + NSPanel instead of
/// SwiftUI's MenuBarExtra, because the panel must be things MenuBarExtra
/// can't: roomy, card-styled, and PINNABLE (a conduit you can hold open
/// while you empty it across apps). Non-activating like the HUD, so
/// opening it never steals focus from your work.
@MainActor
final class MenuBarPanelController {
    private let session: SessionManager
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var stateWatcher: Task<Void, Never>?

    /// Pinned panels ignore outside clicks — glance-and-go by default,
    /// hold-open on request.
    private(set) var isPinned = false

    private static let panelSize = NSSize(width: 420, height: 560)

    private var showObserver: NSObjectProtocol?

    init(session: SessionManager) {
        self.session = session
        installStatusItem()
        watchState()
        showObserver = NotificationCenter.default.addObserver(
            forName: .showMenuBarPanel, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.show() }
        }
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Stable identity: without an autosave name, every rebuild reads as
        // a brand-new item — menu bar managers (Bartender/Ice) auto-hide
        // newcomers, which made the skull "disappear."
        item.autosaveName = "YorickMenuBar"
        if let button = item.button {
            button.image = Self.statusImage
            button.target = self
            button.action = #selector(togglePanel)
        }
        statusItem = item
    }

    /// MenuBarExtra used to do this sizing dance — the status item obeys
    /// the image's INTRINSIC size, so it's set on the NSImage itself.
    private static let statusImage: NSImage = {
        let base = NSImage(named: "MenuBarIcon") ?? NSImage()
        let sized = base.copy() as! NSImage
        sized.size = NSSize(width: 18, height: 18)
        sized.isTemplate = true
        return sized
    }()

    /// Pre-rendered colored variants — contentTintColor on the template SVG
    /// rendered as EMPTY during recording (field report), so state colors
    /// are baked into non-template images and swapped whole.
    private static let recordingImage = tinted(.systemRed)
    private static let transcribingImage = tinted(.systemOrange)
    private static let errorImage = tinted(.systemYellow)

    private static func tinted(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            statusImage.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Image follows session state — same colors the old StatusIndicator used.
    private func watchState() {
        stateWatcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let button = self.statusItem?.button else { return }
                switch self.session.state {
                case .idle: button.image = Self.statusImage
                case .recording: button.image = Self.recordingImage
                case .transcribing: button.image = Self.transcribingImage
                case .error: button.image = Self.errorImage
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    // MARK: - Panel

    @objc func togglePanel() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        installMonitors()
    }

    func hide() {
        removeMonitors()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(
            rootView: MenuBarPanelView(controller: self)
                .environment(session)
                .preferredColorScheme(.dark)
        )
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        return panel
    }

    /// Under the status item, trailing-aligned like every menu bar panel,
    /// clamped to the screen.
    private func position(_ panel: NSPanel) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = buttonFrame.maxX - Self.panelSize.width
        x = min(max(x, visible.minX + 8), visible.maxX - Self.panelSize.width - 8)
        let y = buttonFrame.minY - Self.panelSize.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Glance-and-go: any click outside the panel dismisses it — unless
    /// pinned. Global monitor covers other apps; local covers Yorick's own
    /// windows (the HUD, the main window).
    private func installMonitors() {
        removeMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPinned else { return }
                self.hide()
            }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, !self.isPinned else { return }
                if event.window !== self.panel, event.window !== self.statusItem?.button?.window {
                    self.hide()
                }
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}
