import SwiftUI

struct StatusIndicator: View {
    let state: SessionState

    var body: some View {
        switch state {
        case .idle:
            menuIcon(.primary)
        case .recording:
            menuIcon(.red)
        case .transcribing:
            menuIcon(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    /// MenuBarExtra snapshots its label into an NSStatusItem, which obeys
    /// the image's INTRINSIC size and ignores SwiftUI frame modifiers — the
    /// new SVG's 1024pt intrinsic swallowed the whole menu bar. Sizing must
    /// happen on the NSImage itself.
    private func menuIcon(_ color: some ShapeStyle) -> some View {
        Image(nsImage: Self.statusImage)
            .renderingMode(.template)
            .foregroundStyle(color)
    }

    private static let statusImage: NSImage = {
        let base = NSImage(named: "MenuBarIcon") ?? NSImage()
        // Copy before resizing — NSImage(named:) returns a shared cached
        // instance, and mutating it would shrink every other use.
        let sized = base.copy() as! NSImage
        sized.size = NSSize(width: 18, height: 18)
        sized.isTemplate = true
        return sized
    }()
}
