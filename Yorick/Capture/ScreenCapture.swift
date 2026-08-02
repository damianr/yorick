import AppKit
import CoreGraphics

/// Region screenshots, taken during a recording and attached to the capture.
///
/// A DELIBERATE REVERSAL of ContextCollector's founding line ("no screenshots
/// or Screen Recording — not even on the roadmap"). That line was written
/// when captures had nowhere to go: a screenshot was cost with no story, and
/// Screen Recording was the scariest ask in the onboarding for the least
/// return. A capture that becomes a ticket someone else reads changes the
/// arithmetic — "the alignment is off HERE" is a sentence a crop answers and
/// a thousand words of accessibility text does not.
///
/// The permission is asked for at FIRST USE of the button, never at
/// onboarding, and everything else in the app works without it. Accessibility
/// and Microphone remain the only permissions the product requires.
///
/// The crosshair is the SYSTEM's (`screencapture -i`), not one built here.
/// That buys correct multi-display handling, Retina backing scale, the
/// space-bar window-picker, and Escape-to-cancel — all of which a hand-rolled
/// overlay would have to reimplement and get wrong on someone's monitor
/// arrangement. The tradeoff accepted knowingly: it's a subprocess, and the
/// UI is macOS's rather than Yorick's.
enum ScreenCapture {
    private static let tool = "/usr/sbin/screencapture"

    /// Whether Screen Recording has already been granted. Never prompts.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Ask for Screen Recording. Returns true if it's already granted; a
    /// fresh grant requires a relaunch on macOS, so the caller has to say so
    /// rather than pretend the next call will work.
    @discardableResult
    static func requestAuthorization() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        return false
    }

    enum Failure: Error, LocalizedError {
        case notAuthorized
        case cancelled
        case toolFailed

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Yorick needs Screen Recording to take a screenshot. "
                    + "Grant it in System Settings, then relaunch Yorick."
            case .cancelled:
                return "Screenshot cancelled."
            case .toolFailed:
                return "The screenshot didn't complete."
            }
        }
    }

    /// Run the system crosshair and return the crop as JPEG data.
    ///
    /// Off the main actor: the tool blocks for as long as the user takes to
    /// drag, which is unbounded, and the recording is still running behind it.
    static func selectRegion() async throws -> Data {
        guard isAuthorized else { throw Failure.notAuthorized }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("yorick-shot-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        // -i interactive crosshair · -x silent (the shutter sound over a live
        // recording would land in the transcript) · -t jpg for size · -o no
        // window shadow when the space-bar picker is used.
        process.arguments = ["-i", "-x", "-o", "-t", "jpg", destination.path]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: Failure.toolFailed) }
        }

        // Escape or a right-click cancel exits cleanly and writes nothing,
        // which is a normal outcome rather than an error to report.
        guard let data = try? Data(contentsOf: destination), !data.isEmpty else {
            throw Failure.cancelled
        }
        return data
    }
}
