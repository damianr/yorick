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

        _ = (cursor, pointerParked) // pointer evidence comes from PointerTimeline
        return facts
    }

    // MARK: - Pointed-element resolution (shared with PointerTimeline)

    /// What the pointer is touching, resolved to a SEMANTIC unit, not the
    /// deepest leaf: a bare word under the cursor climbs to its row/cell or
    /// nearest titled container, whose visible text is the fact ("Record ·
    /// Ocrevus · in progress", not "Ocrevus"). One bounded direct-children
    /// text read for rows — never a subtree walk.
    static func resolvePointed(at point: CGPoint) -> (value: String, detail: String)? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var pointedRef: AXUIElement?
        AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &pointedRef)
        guard let leaf = pointedRef else { return nil }

        let leafText = bestText(of: leaf)
        // Climb toward meaning: a row/cell wins outright; otherwise the first
        // ancestor that carries its own title/description.
        var node = leaf
        for _ in 0..<6 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { break }
            node = parent as! AXUIElement
            let role = str(node, kAXRoleAttribute) ?? ""
            if role == "AXRow" || role == "AXCell" {
                let rowText = childrenText(of: node)
                if !rowText.isEmpty {
                    return (String(rowText.prefix(pointedCap)), str(node, kAXRoleDescriptionAttribute) ?? "row")
                }
                break
            }
            // Containers that merely wrap everything don't carry meaning.
            if role == "AXWindow" || role == "AXWebArea" || role == "AXScrollArea" { break }
            let title = str(node, kAXTitleAttribute) ?? str(node, kAXDescriptionAttribute) ?? ""
            if !title.isEmpty, title != leafText {
                let detail = str(node, kAXRoleDescriptionAttribute) ?? role
                return (String(title.prefix(pointedCap)), detail)
            }
        }
        guard let leafText, !leafText.isEmpty else { return nil }
        let roleDesc = str(leaf, kAXRoleDescriptionAttribute) ?? (str(leaf, kAXRoleAttribute) ?? "element")
        return (String(leafText.prefix(pointedCap)), roleDesc)
    }

    private static func bestText(of element: AXUIElement) -> String? {
        let title = str(element, kAXTitleAttribute) ?? ""
        let label = str(element, kAXDescriptionAttribute) ?? ""
        let value = str(element, kAXValueAttribute) ?? ""
        return [title, label, value].first { !$0.isEmpty }
    }

    /// Visible text of a row's DIRECT children, joined — bounded (first 8
    /// children, 200 chars), one level only.
    private static func childrenText(of element: AXUIElement) -> String {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return "" }
        let parts = children.prefix(8).compactMap { bestText(of: $0) }.filter { !$0.isEmpty }
        return String(parts.joined(separator: " · ").prefix(200))
    }

    // MARK: - Pointer timeline

    /// Samples what the pointer touches WHILE the recording runs — pointing
    /// is a gesture, not a moment, and "I mean this whole section" arrives as
    /// a sweep across its rows. Sampling starts at hotkey-down and stops at
    /// release: the recording pill is on screen the whole time, so the
    /// watching is announced. Only fresh pointer positions are sampled (a
    /// parked mouse contributes nothing), consecutive duplicates collapse,
    /// and the ordered unique sweep (capped) becomes the evidence.
    actor PointerTimeline {
        private var items: [(value: String, detail: String)] = []
        private var sampler: Task<Void, Never>?
        private static let maxItems = 8

        func begin() {
            guard sampler == nil else { return }
            let deadline = ContinuousClock.now + .seconds(600)
            sampler = Task {
                while !Task.isCancelled, items.count < Self.maxItems, ContinuousClock.now < deadline {
                    sampleOnce()
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
            }
        }

        private func sampleOnce() {
            // CGEvent's location is already top-left-origin global coords —
            // matching AX — and both CG calls are thread-safe.
            let idle = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .mouseMoved
            )
            guard idle < 2.0, let point = CGEvent(source: nil)?.location else { return }
            guard let resolved = ContextCollector.resolvePointed(at: point) else { return }
            if let last = items.last, last.value == resolved.value { return }
            if items.contains(where: { $0.value == resolved.value }) { return }
            items.append(resolved)
        }

        /// Stop sampling (hotkey release) — items are kept for `finish`.
        func stopSampling() {
            sampler?.cancel()
            sampler = nil
        }

        /// The ordered sweep as facts. Also emits the coverage log line.
        func finish(appName: String) -> [ContextFact] {
            sampler?.cancel()
            sampler = nil
            ContextCollector.logTimeline(appName: appName, count: items.count)
            return items.map {
                ContextFact(kind: "pointedElement", value: $0.value, detail: $0.detail, phase: "timeline")
            }
        }
    }

    // MARK: - Coverage instrumentation

    private static var isLoggingEnabled: Bool { UserDefaults.standard.bool(forKey: "adminMode") }

    static func logTimeline(appName: String, count: Int) {
        guard isLoggingEnabled else { return }
        log.notice("rung=pointerTimeline app=\(appName, privacy: .public) items=\(count)")
    }

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
