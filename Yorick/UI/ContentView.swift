import SwiftUI

/// One view: the stream. No selection mode, no bulk actions, no lifecycle —
/// the interaction inventory is click-to-copy, one filter toggle, scroll.
struct ContentView: View {
    @Environment(SessionManager.self) private var session
    @State private var showSettings = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// Preview escape hatch: `defaults write com.heyyorick.Yorick forceOnboarding
    /// -bool true` replays the first-run flow on an install that has already
    /// completed (or auto-skipped) it. Cleared when the flow finishes.
    @AppStorage("forceOnboarding") private var forceOnboarding = false

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()

            if !hasCompletedOnboarding || forceOnboarding {
                OnboardingView(onDone: {
                    hasCompletedOnboarding = true
                    forceOnboarding = false
                    // The conduit handoff: the window's job ends with
                    // onboarding. Close it, then open the menu bar panel so
                    // "Yorick lives up here now" is shown, not described.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain })?.close()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            NotificationCenter.default.post(name: .showMenuBarPanel, object: nil)
                        }
                    }
                })
            } else {
                StreamView()
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .modifier(HiddenWindowToolbarBackground())
        .toolbar(.visible, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .navigationDestination(isPresented: $showSettings) {
            SettingsView(session: session)
        }
        .onAppear {
            // Existing installs (captures already on disk) predate onboarding —
            // never show them the first-run flow.
            if !hasCompletedOnboarding, !session.captureStore.captures.isEmpty {
                hasCompletedOnboarding = true
            }
        }
    }
}
