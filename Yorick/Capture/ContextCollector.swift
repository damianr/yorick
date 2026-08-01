import AppKit
import ApplicationServices
import os

/// Gathers the evidence bundle around an utterance — selection, page URL,
/// document, pointed elements — as verbatim `ContextFact`s. AX-only (no
/// screenshots, no Screen Recording, no new permissions), no tree walks:
/// named attributes on the focused and pointed elements plus a bounded
/// parent climb.
///
/// Restored 2026-07-31 for the Linear exit. The 2026-07-29 removal was
/// correct for a product with no destination — evidence with nowhere to go is
/// cost without a story. Now there is a destination, and the evidence is what
/// makes a capture into an issue somebody can act on without being there.
///
/// All reads happen on a detached task. Every read is also logged
/// (admin-gated) — availability and latency only, never values:
///   log show --process Yorick --last 2h | grep contextProbe
enum ContextCollector {
    private static let log = Logger(subsystem: "com.heyyorick.Yorick", category: "contextProbe")
    private static let valueCap = 500
    private static let pointedCap = 200

    /// Snapshot the world as it is right now. Returns immediately with a task
    /// the save path awaits after transcription (seconds later — the bundle
    /// is long done by then), so acquisition never delays the pill, the
    /// transcription, or the paste.
    @MainActor
    static func snapshot(phase: String) -> Task<[ContextFact], Never> {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return Task { [] }
        }
        let pid = frontApp.processIdentifier
        guard !isSelf(pid) else { return Task { [] } }
        let appName = frontApp.localizedName ?? "unknown"

        return Task.detached(priority: .utility) {
            collect(phase: phase, pid: pid, appName: appName)
        }
    }

    /// Yorick never cites itself. Pointing at the saved list while speaking
    /// captured OLD transcripts as "screen context" — evidence about the app
    /// rather than the world, and pollution in anything exported. One rule,
    /// no exceptions: the onboarding carve-out died with the observe step.
    private static func isSelf(_ pid: pid_t) -> Bool {
        pid == ProcessInfo.processInfo.processIdentifier
    }

    private static func collect(phase: String, pid: pid_t, appName: String) -> [ContextFact] {
        var facts: [ContextFact] = []
        // NO AXUIElementSetMessagingTimeout, anywhere in this file. Its
        // scoping proved broader than per-reference in practice: collector
        // timeouts poisoned ROUTING's reads to the same app, and slow apps
        // started reporting focused=none while fast ones kept working.
        // Twice. Boundedness lives at the CONSUMER instead — the save path
        // races these tasks against a wall clock, so a hung app costs facts,
        // never the capture.
        let appElement = AXUIElementCreateApplication(pid)

        // Selection on the focused element — the most literal "pointing".
        var t = ContinuousClock.now
        var focusedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        let focused = focusedRef.map { $0 as! AXUIElement }
        let focusedRole = focused.flatMap { str($0, kAXRoleAttribute) } ?? "none"
        // Secure fields are never read, never transmitted, never logged.
        // This mattered locally; with a network exit downstream it is the
        // difference between a bug and a breach.
        if focusedRole != "AXSecureTextField",
           let selection = focused.flatMap({ str($0, kAXSelectedTextAttribute) }),
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

        return facts
    }

    // MARK: - Pointed-element resolution

    /// What the pointer is touching, resolved to a SEMANTIC unit, not the
    /// deepest leaf: a bare word under the cursor climbs to its row/cell or
    /// nearest titled container, whose visible text is the fact ("Invoices ·
    /// overdue · 12", not "overdue"). One bounded direct-children text read
    /// for rows — never a subtree walk.
    static func resolvePointed(at point: CGPoint) -> (value: String, detail: String)? {
        // No messaging timeouts here either — see collect() for the scars.
        let systemWide = AXUIElementCreateSystemWide()
        var pointedRef: AXUIElement?
        AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &pointedRef)
        guard let leaf = pointedRef else { return nil }
        // Pointing at the pill, card, or saved list is not evidence about the
        // world — this is the cross-app path of the isSelf rule (the HUD
        // floats over other apps, so hit-testing can land on Yorick even when
        // another app is frontmost).
        var ownerPID: pid_t = 0
        AXUIElementGetPid(leaf, &ownerPID)
        guard !isSelf(ownerPID) else { return nil }
        guard str(leaf, kAXRoleAttribute) != "AXSecureTextField" else { return nil }

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
    /// a sweep across its rows rather than one frozen word. Sampling runs
    /// from hotkey-down to release, exactly while the pill is on screen, so
    /// the watching is announced for its whole duration.
    ///
    /// Only FRESH pointer positions are sampled: holding the hotkey means
    /// hands on the keyboard, so a mouse left where it was yesterday is not a
    /// gesture and contributes nothing.
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
            guard AccessibilityCapture.pointerIdleSeconds() < 2.0,
                  let point = CGEvent(source: nil)?.location else { return }
            guard let resolved = ContextCollector.resolvePointed(at: point) else { return }
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
            stopSampling()
            ContextCollector.logTimeline(appName: appName, count: items.count)
            return items.map {
                ContextFact(kind: "pointedElement", value: $0.value, detail: $0.detail, phase: "timeline")
            }
        }
    }

    // MARK: - Coverage instrumentation

    private static var isLoggingEnabled: Bool { AdminMode.enabled }

    static func logTimeline(appName: String, count: Int) {
        guard isLoggingEnabled else { return }
        log.notice("rung=pointerTimeline app=\(appName, privacy: .public) items=\(count)")
    }

    private static func logRung(
        _ phase: String, _ app: String, _ rung: String,
        ok: Bool, since start: ContinuousClock.Instant, detail: String
    ) {
        guard isLoggingEnabled else { return }
        let elapsed = (ContinuousClock.now - start).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        // .public throughout: os.Logger redacts interpolated strings by
        // default. This channel is admin-opt-in, and values are NOT logged
        // here (only availability and latency) — the facts themselves live on
        // the capture, on the same ephemerality clock as everything else.
        log.notice("phase=\(phase, privacy: .public) app=\(app, privacy: .public) rung=\(rung, privacy: .public) ok=\(ok ? 1 : 0) ms=\(String(format: "%.1f", ms), privacy: .public) \(detail, privacy: .public)")
    }

    private static func str(_ element: AXUIElement, _ attr: String) -> String? {
        AccessibilityCapture.attribute(element, attr) as? String
    }
}
