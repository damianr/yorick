import SwiftUI

/// The window's ONLY job is onboarding. An onboarded launch renders nothing
/// and closes the window before it can paint; everything else in the product
/// lives in the menu bar panel and the HUD.
struct ContentView: View {
    @Environment(SessionManager.self) private var session
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// Preview escape hatch: `defaults write com.heyyorick.Yorick forceOnboarding
    /// -bool true` replays the first-run flow on an install that has already
    /// completed (or auto-skipped) it. Cleared when the flow finishes.
    @AppStorage("forceOnboarding") private var forceOnboarding = false

    private var needsOnboarding: Bool { !hasCompletedOnboarding || forceOnboarding }

    var body: some View {
        ZStack {
            if needsOnboarding {
                Theme.bgPrimary.ignoresSafeArea()
                OnboardingView(onDone: {
                    hasCompletedOnboarding = true
                    forceOnboarding = false
                    // The conduit handoff: the window's job ends with
                    // onboarding. Close it, drop out of the Dock/⌘Tab for
                    // good, then open the menu bar panel so "Yorick lives
                    // up here now" is shown, not described.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        Self.closeMainWindow()
                        NSApp.setActivationPolicy(.accessory)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            NotificationCenter.default.post(name: .showMenuBarPanel, object: nil)
                        }
                    }
                })
            } else {
                // Nothing to show — keep the frame invisible and close it
                // before it draws (the alpha guard covers the frames between
                // appearance and close).
                Color.clear
                    .onAppear {
                        NSApp.windows
                            .first(where: { !($0 is NSPanel) && $0.canBecomeMain })?
                            .alphaValue = 0
                        DispatchQueue.main.async { Self.closeMainWindow() }
                    }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private static func closeMainWindow() {
        NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain })?.close()
    }
}
