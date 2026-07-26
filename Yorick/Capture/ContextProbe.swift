import AppKit
import ApplicationServices
import os

/// SPIKE INSTRUMENTATION — not product code, delete when the context-bundle
/// design lands. Answers the enrichment plan's highest-variance question with
/// real usage instead of a lab day: which AX facts (selection, page URL,
/// document path, pointed element) are actually readable in the apps this
/// user talks to daily, and what does reading them cost?
///
/// Admin-gated (`defaults write com.heyyorick.Yorick adminMode -bool true`),
/// logs to the unified log and persists NOTHING — the enrichment plan keeps
/// context out of diagnostics by default, and this probe is the explicit
/// opt-in audit channel (values truncated to 60 chars).
///
/// Read results:
///   log show --process Yorick --last 2h | grep contextProbe
enum ContextProbe {
    private static let log = Logger(subsystem: "com.heyyorick.Yorick", category: "contextProbe")

    private static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "adminMode") }

    /// Fire-and-forget; hops off the caller's path immediately. AX calls are
    /// synchronous IPC into the target app, so all reads happen on a detached
    /// task with a messaging timeout — a hung app costs the probe, never the
    /// session.
    @MainActor
    static func sample(phase: String) {
        guard isEnabled else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName ?? "unknown"
        let cursor = AccessibilityCapture.axCursorPoint()
        // Same primitive routing already trusts: a parked pointer means the
        // mouse is wherever it was left, so pointer-derived facts are suspect.
        let pointerParked = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .mouseMoved
        ) > 3.0

        Task.detached(priority: .utility) {
            probe(phase: phase, pid: pid, appName: appName, cursor: cursor, pointerParked: pointerParked)
        }
    }

    private static func probe(phase: String, pid: pid_t, appName: String, cursor: CGPoint, pointerParked: Bool) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        // Rung 2 — selection on the focused element.
        var t = ContinuousClock.now
        var focusedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        let focused = focusedRef.map { $0 as! AXUIElement }
        let focusedRole = focused.flatMap { str($0, kAXRoleAttribute) } ?? "none"
        let selection = focused.flatMap { str($0, kAXSelectedTextAttribute) } ?? ""
        logRung(phase, appName, "selection", ok: !selection.isEmpty, since: t,
                detail: "focusedRole=\(focusedRole) len=\(selection.count) preview=\(clip(selection))")

        // Rung 3a — page URL from the web area (walk UP only, never down).
        t = ContinuousClock.now
        var webURL = ""
        if var node = focused {
            for _ in 0..<10 {
                if str(node, kAXRoleAttribute) == "AXWebArea" {
                    var urlRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(node, "AXURL" as CFString, &urlRef)
                    webURL = (urlRef as? URL)?.absoluteString ?? ""
                    break
                }
                var parentRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef) == .success,
                      let parent = parentRef else { break }
                node = parent as! AXUIElement
            }
        }
        logRung(phase, appName, "webURL", ok: !webURL.isEmpty, since: t, detail: "url=\(clip(webURL))")

        // Rung 3b — document identity on the focused window.
        t = ContinuousClock.now
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        let document = windowRef.flatMap { str($0 as! AXUIElement, kAXDocumentAttribute) } ?? ""
        logRung(phase, appName, "document", ok: !document.isEmpty, since: t, detail: "doc=\(clip(document))")

        // Rung 4 — element under the pointer + a short ancestor role chain.
        t = ContinuousClock.now
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var pointedRef: AXUIElement?
        AXUIElementCopyElementAtPosition(systemWide, Float(cursor.x), Float(cursor.y), &pointedRef)
        var pointedDetail = "parked=\(pointerParked)"
        var pointedOK = false
        if let pointed = pointedRef {
            let role = str(pointed, kAXRoleAttribute) ?? "none"
            let title = str(pointed, kAXTitleAttribute) ?? ""
            let value = str(pointed, kAXValueAttribute) ?? ""
            var chain: [String] = []
            var node = pointed
            for _ in 0..<5 {
                var parentRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef) == .success,
                      let parent = parentRef else { break }
                node = parent as! AXUIElement
                chain.append(str(node, kAXRoleAttribute) ?? "?")
            }
            pointedOK = !title.isEmpty || !value.isEmpty
            pointedDetail += " role=\(role) title=\(clip(title)) valueLen=\(value.count) chain=\(chain.joined(separator: ">"))"
        }
        logRung(phase, appName, "pointed", ok: pointedOK, since: t, detail: pointedDetail)
    }

    // MARK: - Helpers

    private static func logRung(_ phase: String, _ app: String, _ rung: String, ok: Bool, since start: ContinuousClock.Instant, detail: String) {
        let elapsed = (ContinuousClock.now - start).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        // .public throughout: os.Logger redacts interpolated strings by
        // default, which would turn the whole spike into "<private>". This
        // channel is admin-opt-in and truncated by design.
        log.info("phase=\(phase, privacy: .public) app=\(app, privacy: .public) rung=\(rung, privacy: .public) ok=\(ok ? 1 : 0) ms=\(String(format: "%.1f", ms), privacy: .public) \(detail, privacy: .public)")
    }

    private static func str(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func clip(_ s: String) -> String {
        s.isEmpty ? "-" : "\"\(s.prefix(60))\""
    }
}
