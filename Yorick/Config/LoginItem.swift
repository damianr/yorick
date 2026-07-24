import ServiceManagement

/// Launch-at-login via SMAppService — the transparent, user-revocable path:
/// registration is visible in System Settings → General → Login Items (macOS
/// notifies the user when it happens), and flipping it off there just works.
/// Yorick only hears the hotkey while running, so this is offered (never
/// forced) during onboarding and lives as a toggle in Settings.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state, so callers reflect reality rather than intent
    /// (registration can fail silently, e.g. running from a translocated path).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[LoginItem] \(enabled ? "register" : "unregister") failed: \(error)")
        }
        return isEnabled
    }
}
