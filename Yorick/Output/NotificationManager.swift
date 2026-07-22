import UserNotifications

@MainActor
enum NotificationManager {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func sendCaptureSaved(mode: CaptureMode) {
        let content = UNMutableNotificationContent()
        content.title = "Yorick"
        content.body = mode == .dictation ? "Dictation captured" : "Capture saved"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func sendFailure(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording Failed"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
