import SwiftUI

@main
struct YorickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            NavigationStack {
                ContentView()
                    .environment(appDelegate.sessionManager)
            }
            .preferredColorScheme(.dark)
            .onAppear { styleMainWindow() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 580)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.sessionManager)
        } label: {
            StatusIndicator(
                state: appDelegate.sessionManager.state
            )
        }
        .menuBarExtraStyle(.window)
    }

    private func styleMainWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) else { return }

            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = NSColor(red: 0.031, green: 0.031, blue: 0.043, alpha: 1.0) // Theme.bgPrimary
            window.titlebarSeparatorStyle = .none
            window.isMovableByWindowBackground = true

            // Add custom buttons to the titlebar area using NSTitlebarAccessoryViewController
            let accessory = NSTitlebarAccessoryViewController()
            let buttons = NSHostingView(rootView:
                TitlebarButtons(sessionManager: appDelegate.sessionManager)
            )
            buttons.frame = NSRect(x: 0, y: 0, width: 80, height: 38)
            accessory.view = buttons
            accessory.layoutAttribute = .trailing
            accessory.fullScreenMinHeight = 38
            window.addTitlebarAccessoryViewController(accessory)
        }
    }
}
