import UserNotifications

/// Identifiers for the vocabulary-suggestion notification. Outside the
/// main-actor enum so the (nonisolated) notification delegate can match them.
enum VocabularyNotification {
    static let category = "vocabularySuggestion"
    static let acceptAction = "vocabulary.accept"
    static let dismissAction = "vocabulary.dismiss"
    static let heardKey = "heard"
    static let termKey = "term"
}

@MainActor
enum NotificationManager {
    static func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: VocabularyNotification.category,
                actions: [
                    UNNotificationAction(identifier: VocabularyNotification.acceptAction, title: "Always", options: []),
                    UNNotificationAction(identifier: VocabularyNotification.dismissAction, title: "No Thanks", options: []),
                ],
                intentIdentifiers: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// "You changed 'weights' to 'Waits'" — offered once per fix. The same
    /// suggestion waits in Settings › Vocabulary if this is missed or
    /// notifications are off.
    static func sendVocabularySuggestion(_ suggestion: VocabularySuggestion) {
        let content = UNMutableNotificationContent()
        content.title = "Always type \u{201C}\(suggestion.term)\u{201D}?"
        content.body = "You changed \u{201C}\(suggestion.heard)\u{201D} to \u{201C}\(suggestion.term)\u{201D}. Yorick can type it your way every time."
        content.categoryIdentifier = VocabularyNotification.category
        content.userInfo = [
            VocabularyNotification.heardKey: suggestion.heard,
            VocabularyNotification.termKey: suggestion.term,
        ]

        let request = UNNotificationRequest(
            identifier: "vocabulary-\(suggestion.heard)-\(suggestion.term)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
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
