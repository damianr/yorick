import SwiftUI

@main
struct YorickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Yorick is an accessory app (LSUIElement): no Dock icon, no ⌘Tab. The
    // one window this scene produces exists ONLY for onboarding — a launch
    // that's already onboarded closes it before it can paint (ContentView),
    // and the activation policy flips to .regular solely while onboarding
    // runs (AppDelegate). The SwiftUI lifecycle stays because it provides
    // the standard Edit menu, which the synthesized ⌘V needs to land in
    // onboarding's own practice field.
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appDelegate.sessionManager)
                .preferredColorScheme(.dark)
                .onAppear { styleOnboardingWindow() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 580)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        // The menu bar surface is a custom NSStatusItem + NSPanel
        // (MenuBarPanelController, installed by AppDelegate) — MenuBarExtra
        // couldn't give the panel the room, card styling, or pinning the
        // conduit design needs.
    }

    private func styleOnboardingWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(red: 0.031, green: 0.031, blue: 0.043, alpha: 1.0) // Theme.bgPrimary
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true
            window.isRestorable = false
        }
    }
}
