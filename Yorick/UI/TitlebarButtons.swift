import SwiftUI

/// Buttons placed in the titlebar area via NSTitlebarAccessoryViewController.
/// Aligned with the traffic lights on the right side.
struct TitlebarButtons: View {
    let sessionManager: SessionManager

    var body: some View {
        HStack(spacing: 14) {
            Button(action: {
                if sessionManager.state == .recording { sessionManager.stopIfRecording() }
                else { sessionManager.startIfIdle() }
            }) {
                Image(systemName: sessionManager.state == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(sessionManager.state == .recording ? .red : .secondary)
            }
            .buttonStyle(.plain)

            Button(action: {
                // Post notification to open settings — ContentView listens for it
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }) {
                Image(systemName: "gear")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 10)
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
    /// Posted from the menu bar to trigger a Sparkle update check.
    static let checkForUpdates = Notification.Name("checkForUpdates")
}
