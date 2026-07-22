import SwiftUI

/// One view: the stream. No selection mode, no bulk actions, no lifecycle —
/// the interaction inventory is click-to-copy, one filter toggle, scroll.
struct ContentView: View {
    @Environment(SessionManager.self) private var session
    @State private var showSettings = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()

            if !hasCompletedOnboarding {
                OnboardingView(onDone: { hasCompletedOnboarding = true })
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
