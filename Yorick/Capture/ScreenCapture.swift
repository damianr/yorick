import AppKit
import CoreGraphics
import ScreenCaptureKit

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
/// The crosshair is OURS (`RegionSelector`), not `screencapture -i`.
///
/// The system tool was the right first call and the wrong one here: its
/// crosshair reads modifier keys, Option means "resize from the centre," and
/// Yorick's recording is push-to-talk — so ⌥Space is necessarily HELD while
/// you frame the shot and every drag came out centre-anchored. No flag turns
/// that off; the conflict is structural. Owning the overlay fixes the anchor,
/// ignores modifiers on purpose, and drops the subprocess.
enum ScreenCapture {

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

    /// Frame a region and return the crop as JPEG data.
    @MainActor
    static func selectRegion() async throws -> Data {
        guard isAuthorized else { throw Failure.notAuthorized }

        let selector = RegionSelector()
        guard let rect = await selector.selectRegion() else { throw Failure.cancelled }
        // One runloop turn so the overlay is really gone before the shutter —
        // ordering it out is not the same as it having finished drawing, and
        // a dimmed band across the crop is the tell.
        try? await Task.sleep(nanoseconds: 60_000_000)

        guard let image = try? await capture(rect: rect) else { throw Failure.toolFailed }
        guard let data = jpeg(from: image) else { throw Failure.toolFailed }
        return data
    }

    /// Grab the pixels via ScreenCaptureKit, which is the supported path on
    /// macOS 14+ (`CGWindowListCreateImage` is deprecated there and warns).
    @MainActor
    private static func capture(rect: CGRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        // The display the selection starts on. A rect spanning two monitors
        // captures from the one it began on rather than failing — a partial
        // shot beats an error the user can't act on.
        let display = content.displays.first { display in
            display.frame.intersects(rect)
        } ?? content.displays.first
        guard let display else { throw Failure.toolFailed }

        let configuration = SCStreamConfiguration()
        // sourceRect is relative to the display's own origin.
        let local = CGRect(
            x: rect.minX - display.frame.minX,
            y: rect.minY - display.frame.minY,
            width: rect.width,
            height: rect.height
        )
        configuration.sourceRect = local
        // Backing scale, so a Retina crop stays sharp instead of being
        // resampled down to points.
        let scale = NSScreen.screens.first { NSPointInRect(rect.origin, $0.frame) }?.backingScaleFactor ?? 2
        configuration.width = Int(local.width * scale)
        configuration.height = Int(local.height * scale)
        configuration.captureResolution = .best
        configuration.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )
    }

    private static func jpeg(from image: CGImage, quality: CGFloat = 0.8) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
