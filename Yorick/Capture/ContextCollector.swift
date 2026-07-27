import AppKit
import ApplicationServices
import os

/// Layer B of the enrichment plan: gathers the evidence bundle around an
/// utterance — selection, page URL, document, pointed element — as verbatim
/// `ContextFact`s. AX-only, two permissions, no tree walks (named attributes
/// on the focused/pointed element and a parent climb only).
///
/// All reads happen on a detached task with per-app messaging timeouts: AX is
/// synchronous IPC, and a hung app must cost the bundle, never the session.
/// Every read is also logged (admin-gated) to the unified log — the coverage
/// instrumentation that decides which rungs earn deeper work lives INSIDE the
/// collector, measuring the feature's real use instead of a separate spike:
///   log show --process Yorick --last 2h | grep contextProbe
enum ContextCollector {
    private static let log = Logger(subsystem: "com.heyyorick.Yorick", category: "contextProbe")
    private static let valueCap = 500
    private static let pointedCap = 200

    /// Snapshot the world as it is right now. Returns immediately with a task
    /// the save path awaits after transcription (seconds later — the bundle
    /// is long done by then).
    @MainActor
    static func snapshot(phase: String) -> Task<[ContextFact], Never> {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return Task { [] }
        }
        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName ?? "unknown"
        let cursor = AccessibilityCapture.axCursorPoint()
        // The same primitive routing trusts: a parked pointer is wherever it
        // was left, so pointer-derived facts are included only when the
        // pointer was recently, deliberately moved.
        let pointerParked = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .mouseMoved
        ) > 3.0

        return Task.detached(priority: .utility) {
            collect(phase: phase, pid: pid, appName: appName, cursor: cursor, pointerParked: pointerParked)
        }
    }

    private static func collect(
        phase: String, pid: pid_t, appName: String, cursor: CGPoint, pointerParked: Bool
    ) -> [ContextFact] {
        var facts: [ContextFact] = []
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        // Selection on the focused element — the most literal "pointing".
        var t = ContinuousClock.now
        var focusedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        let focused = focusedRef.map { $0 as! AXUIElement }
        let focusedRole = focused.flatMap { str($0, kAXRoleAttribute) } ?? "none"
        if let selection = focused.flatMap({ str($0, kAXSelectedTextAttribute) }),
           !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            facts.append(ContextFact(
                kind: "selection",
                value: String(selection.prefix(valueCap)),
                detail: focusedRole,
                phase: phase
            ))
        }
        logRung(phase, appName, "selection", ok: facts.contains { $0.kind == "selection" }, since: t,
                detail: "focusedRole=\(focusedRole)")

        // Page identity: climb from the focused element to a web area, read
        // its URL. Climb only — descending a web page costs hundreds of ms.
        t = ContinuousClock.now
        if var node = focused {
            for _ in 0..<10 {
                if str(node, kAXRoleAttribute) == "AXWebArea" {
                    var urlRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(node, "AXURL" as CFString, &urlRef)
                    if let url = (urlRef as? URL)?.absoluteString, !url.isEmpty {
                        facts.append(ContextFact(kind: "pageURL", value: url, detail: nil, phase: phase))
                    }
                    break
                }
                var parentRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef) == .success,
                      let parent = parentRef else { break }
                node = parent as! AXUIElement
            }
        }
        logRung(phase, appName, "pageURL", ok: facts.contains { $0.kind == "pageURL" }, since: t, detail: "")

        // Document identity on the focused window (document-based apps).
        t = ContinuousClock.now
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        if let document = windowRef.flatMap({ str($0 as! AXUIElement, kAXDocumentAttribute) }), !document.isEmpty {
            facts.append(ContextFact(kind: "document", value: document, detail: nil, phase: phase))
        }
        logRung(phase, appName, "document", ok: facts.contains { $0.kind == "document" }, since: t, detail: "")

        // What the pointer touched — only when the pointer was actually in
        // use. Named attributes on the element itself; no radius walks.
        t = ContinuousClock.now
        var pointedOK = false
        if !pointerParked {
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, 0.25)
            var pointedRef: AXUIElement?
            AXUIElementCopyElementAtPosition(systemWide, Float(cursor.x), Float(cursor.y), &pointedRef)
            if let pointed = pointedRef {
                let role = str(pointed, kAXRoleAttribute) ?? "unknown"
                let title = str(pointed, kAXTitleAttribute) ?? ""
                let value = str(pointed, kAXValueAttribute) ?? ""
                let label = str(pointed, kAXDescriptionAttribute) ?? ""
                let best = [title, label, value].first { !$0.isEmpty } ?? ""
                if !best.isEmpty {
                    let roleDesc = str(pointed, kAXRoleDescriptionAttribute) ?? role
                    facts.append(ContextFact(
                        kind: "pointedElement",
                        value: String(best.prefix(pointedCap)),
                        detail: roleDesc,
                        phase: phase
                    ))
                    pointedOK = true
                }
            }
        }
        logRung(phase, appName, "pointed", ok: pointedOK, since: t, detail: "parked=\(pointerParked)")

        return facts
    }

    // MARK: - Coverage instrumentation

    private static var isLoggingEnabled: Bool { UserDefaults.standard.bool(forKey: "adminMode") }

    private static func logRung(_ phase: String, _ app: String, _ rung: String, ok: Bool, since start: ContinuousClock.Instant, detail: String) {
        guard isLoggingEnabled else { return }
        let elapsed = (ContinuousClock.now - start).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        // .public throughout: os.Logger redacts interpolated strings by
        // default. This channel is admin-opt-in; values are NOT logged here
        // (only availability + latency) — the facts themselves live on the
        // capture, on the same ephemerality clock as everything else.
        log.notice("phase=\(phase, privacy: .public) app=\(app, privacy: .public) rung=\(rung, privacy: .public) ok=\(ok ? 1 : 0) ms=\(String(format: "%.1f", ms), privacy: .public) \(detail, privacy: .public)")
    }

    private static func str(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
