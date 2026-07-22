import Foundation

/// Renders a Capture into copyable text for pasting into AI tools.
/// Prefers structured `content` from the classifier, falling back to the legacy
/// `processedInstructions` field, then to the raw transcript.
///
/// No app-name header — the user is already in context when they paste
/// (e.g., in a Claude Code session for that project).
enum CaptureRenderer {
    static func render(_ capture: Capture) -> String {
        capture.content ?? capture.processedInstructions ?? capture.transcript
    }
}
