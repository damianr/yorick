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

    /// The mark's SVG has a 1024pt intrinsic size — unconstrained, it
    /// swallowed the menu bar. Menu bar template icons are ~18pt.
    private func menuIcon(_ color: some ShapeStyle) -> some View {
        Image("MenuBarIcon")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 18, height: 18)
            .foregroundStyle(color)
    }
}
