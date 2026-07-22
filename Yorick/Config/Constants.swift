import Foundation

enum Constants {
    // Capture
    static let screenshotJPEGQuality: CGFloat = 0.5
    static let cursorSampleIntervalSeconds: TimeInterval = 0.1 // 10 Hz

    // Storage
    static let captureRetentionDays = 30
    /// Pure dictations are ephemeral — the text already lives in its target
    /// document. Anything the user ever flipped to a note keeps the full
    /// retention window.
    static let dictationRetentionDays = 7
    /// Recordings at least this long are never silently dropped by quality
    /// gates — they save flagged with audio retained instead. The gates were
    /// tuned on short clips; a false positive on a ramble costs minutes.
    static let neverDropDurationSeconds = 20
    /// Done items (checked-off todos, exported reviews) fade after a grace
    /// window — artifacts exit the stream, they don't accumulate.
    static let doneRetentionDays = 7

}
