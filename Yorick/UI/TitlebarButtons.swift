import SwiftUI

/// Buttons placed in the titlebar area via NSTitlebarAccessoryViewController.
/// Aligned with the traffic lights on the right side.
struct TitlebarButtons: View {
    let sessionManager: SessionManager
    // Onboarding is a standalone moment — no app chrome floating over it.
    // AppStorage-reactive: the buttons appear the instant the flow finishes.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("forceOnboarding") private var forceOnboarding = false

    var body: some View {
        if hasCompletedOnboarding, !forceOnboarding {
            buttons
        }
    }

    private var buttons: some View {
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
    /// Opens the menu bar panel — the onboarding handoff's "it lives up
    /// here now" moment, shown rather than described.
    static let showMenuBarPanel = Notification.Name("showMenuBarPanel")
    /// Posted from the menu bar to trigger a Sparkle update check.
    static let checkForUpdates = Notification.Name("checkForUpdates")
}
