import AppKit
import ApplicationServices
import KeyboardShortcuts
import UserNotifications
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let sessionManager = SessionManager()
    private var menuBarPanel: MenuBarPanelController?
    private var hudWindow: HUDWindow?

    /// Sparkle auto-updates. Checks the appcast on a schedule and on demand
    /// (the "Check for Updates…" menu item posts .checkForUpdates). Updates
    /// are EdDSA-signed — a tampered download is rejected even if the host is
    /// compromised — which keeps the "nothing leaves your Mac" story honest:
    /// the only network call is fetching the signed appcast.
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerHotkeys()
        // Parse the 3D skull off-main now so the recording pill never waits
        // on it — the pill appears at hotkey speed or the experiment loses.
        SkullGazeView.preload()
        // The menu bar surface: custom status item + card-styled panel.
        menuBarPanel = MenuBarPanelController(session: sessionManager)

        let trusted = AXIsProcessTrusted()
        print("[AppDelegate] Accessibility trusted: \(trusted)")
        // Only surface the system prompt for RETURNING users who've somehow lost
        // the grant. First-run users reach the Accessibility step in onboarding,
        // which drives the prompt in context — firing it at launch jumped ahead
        // of that flow and greeted brand-new users with a bare system dialog.
        if !trusted, UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            // Literal key: kAXTrustedCheckOptionPrompt is a global var and not
            // concurrency-safe under Swift 6 strict checking.
            let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        // Cap AX round-trips process-wide. The default timeout is several
        // seconds, so a beachballing target app could hang our 2Hz context
        // polling (and the HUD) for the duration.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        UNUserNotificationCenter.current().delegate = self
        NotificationManager.requestPermission()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        NotificationCenter.default.addObserver(
            forName: .checkForUpdates, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updaterController?.updater.checkForUpdates()
        }

        // Prune old captures on launch
        sessionManager.captureStore.pruneOld(olderThan: Constants.captureRetentionDays)
        sessionManager.captureStore.pruneEphemeralDictations(olderThan: Constants.dictationRetentionDays)
        sessionManager.captureStore.pruneDone(olderThan: Constants.doneRetentionDays)

        // Whisper is the opt-in engine — never cost a fresh install a 600MB
        // download when Apple Speech is the zero-setup default.
        Task.detached {
            WhisperServer.cleanupLegacyModels()
            guard TranscriptionEngine.preferred == .whisper else { return }
            if !FileManager.default.fileExists(atPath: WhisperServer.modelPath) && WhisperServer.isBundled {
                do {
                    try await WhisperServer.downloadModelIfNeeded { progress in
                        print("[WhisperServer] Download: \(Int(progress * 100))%")
                    }
                } catch {
                    print("[WhisperServer] Model download failed: \(error)")
                    return
                }
            }
            // Small VAD model — best-effort, lets the server trim silence.
            await WhisperServer.downloadVADModelIfNeeded()
            WhisperServer.ensureRunning()
        }

        // Create floating HUD
        let hud = HUDWindow(sessionManager: sessionManager)
        hud.orderFront(nil)
        hudWindow = hud
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Don't leave an orphaned whisper-server behind — it would survive the
        // app and keep serving a stale model after an update.
        WhisperServer.shutdown()
    }

    private func registerHotkeys() {
        print("[Hotkeys] Registering hotkeys...")
        HotkeyManager.registerAll(
            onKeyDown: { [weak self] in
                print("[Hotkeys] KEY DOWN — starting capture")
                self?.sessionManager.startIfIdle()
            },
            onKeyUp: { [weak self] in
                print("[Hotkeys] KEY UP — stopping capture")
                self?.sessionManager.stopIfRecording()
            }
        )
        print("[Hotkeys] Registration complete")
    }

    // Show notifications even when app is in foreground
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Re-open the main window when the user clicks the Dock icon with no visible windows
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows
                .first { !($0 is NSPanel) && $0.canBecomeMain }?
                .makeKeyAndOrderFront(nil)
        }
        return true
    }

    // Handle notification click — open main window
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
