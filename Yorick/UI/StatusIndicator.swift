import SwiftUI

struct StatusIndicator: View {
    let state: SessionState

    var body: some View {
        switch state {
        case .idle:
            Image("MenuBarIcon")
                .renderingMode(.template)
        case .recording:
            Image("MenuBarIcon")
                .renderingMode(.template)
                .foregroundStyle(.red)
        case .transcribing:
            Image("MenuBarIcon")
                .renderingMode(.template)
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}
