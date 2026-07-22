import SwiftUI
import AppKit

/// Adds a solid backdrop behind the window's titlebar/toolbar area.
/// The backdrop opacity is controlled by a binding, allowing scroll-aware behavior.
struct ToolbarBackdrop: NSViewRepresentable {
    let isVisible: Bool
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Delay to ensure the window hierarchy is set up
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            installBackdrop(in: window, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let backdrop = context.coordinator.backdrop else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            backdrop.animator().alphaValue = isVisible ? 1.0 : 0.0
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func installBackdrop(in window: NSWindow, context: Context) {
        guard context.coordinator.backdrop == nil else { return }

        // Find the titlebar container view
        // It's typically: NSThemeFrame > NSTitlebarContainerView > NSTitlebarView
        guard let themeFrame = window.contentView?.superview else { return }

        var titlebarContainer: NSView?
        for subview in themeFrame.subviews {
            if String(describing: type(of: subview)).contains("NSTitlebarContainerView") {
                titlebarContainer = subview
                break
            }
        }

        guard let container = titlebarContainer else { return }

        // Create our backdrop view — sits at the back of the titlebar container
        let backdrop = NSView(frame: container.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = color.cgColor
        backdrop.alphaValue = isVisible ? 1.0 : 0.0

        // Insert at the back (behind all titlebar content)
        container.addSubview(backdrop, positioned: .below, relativeTo: container.subviews.first)

        context.coordinator.backdrop = backdrop
    }

    class Coordinator {
        var backdrop: NSView?
    }
}
