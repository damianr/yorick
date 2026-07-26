import AppKit
import ApplicationServices

/// Captures accessibility information about the UI element under the cursor.
/// Works across all macOS apps — gives us element role, title, value, and parent hierarchy.
struct ElementContext: Sendable {
    let role: String           // e.g. "AXButton", "AXTextField", "AXStaticText"
    let subrole: String?       // e.g. "AXSecureTextField", "AXContentEditable"
    let title: String?         // e.g. "Save", "Submit"
    let value: String?         // e.g. text content of a field
    let roleDescription: String? // e.g. "button", "text field"
    let label: String?         // accessibility label
    let identifier: String?    // accessibility identifier (often maps to test IDs)
    let parentChain: [String]  // e.g. ["AXGroup", "AXWindow", "AXApplication"]
    let appName: String        // app owning the element under cursor
    let windowTitle: String?   // title of the window containing the element

    var description: String {
        var parts: [String] = []

        parts.append("App: \(appName)")
        parts.append("Element: \(roleDescription ?? role)")
        if let title, !title.isEmpty { parts.append("Title: \"\(title.prefix(80))\"") }
        if let label, !label.isEmpty, label != title { parts.append("Label: \"\(label.prefix(80))\"") }
        if let value, !value.isEmpty { parts.append("Value: \"\(value.prefix(100))\"") }
        if let identifier, !identifier.isEmpty { parts.append("ID: \(identifier)") }
        if !parentChain.isEmpty { parts.append("In: \(parentChain.prefix(3).joined(separator: " → "))") }

        return parts.joined(separator: " | ")
    }
}

enum AccessibilityCapture {
    struct EditabilityDecision: Sendable {
        /// How much the pre-speech evidence should be trusted. `.high` verdicts
        /// stick; `.low` verdicts are a prior the transcript can override after
        /// transcription (see UtteranceRouter).
        enum Confidence: String, Sendable {
            case high
            case low
        }

        let isEditable: Bool
        let confidence: Confidence
        let summary: String
        let cursorContext: ElementContext?
    }

    private struct FocusedEditability {
        let isEditable: Bool
        let summary: String
        /// Frame of the focused element (global top-left coords) when known.
        let frame: CGRect?
        /// The editable element itself — its identity lets the HUD detect
        /// "same field?" across ticks, not just "same rectangle?".
        var element: AXUIElement? = nil
    }

    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
    ]

    /// Rich editors whose focused canvas is AX-opaque: it exposes no editable
    /// role, no settable value, and no text attributes we can read (verified via
    /// AX probe — Pages focuses a bare AXScrollArea, Word/Keynote similar). A ⌘V
    /// paste still lands, so we trust app identity: if one of these is frontmost
    /// and a plausible text container is focused, treat it as a dictation target.
    private static let richEditorBundleIDs: Set<String> = [
        "com.apple.iWork.Pages",
        "com.apple.iWork.Keynote",
        "com.apple.iWork.Numbers",
        "com.apple.mail",              // also caught by settable-value, listed for clarity
        "com.microsoft.Word",
        "com.microsoft.Powerpoint",
        "com.microsoft.Excel",
        "com.microsoft.Outlook",
        "com.literatureandlatte.scrivener3",
        "com.coteditor.CotEditor",
        "com.apple.TextEdit"
    ]

    /// Roles that can plausibly hold a text cursor in a rich editor. Guards the
    /// bundle-ID trust path so a focused button/slider/menu in Pages is never
    /// mistaken for the document canvas.
    private static let textContainerRoles: Set<String> = [
        "AXScrollArea", "AXTextArea", "AXTextField", "AXWebArea",
        "AXGroup", "AXLayoutArea", "AXUnknown"
    ]

    /// The cursor location in AX hit-test coordinates (global, top-left origin).
    /// The flip must use the PRIMARY screen (`screens[0]`) — `NSScreen.main` is
    /// the key window's screen and gives wrong coordinates on multi-display setups.
    static func axCursorPoint() -> CGPoint {
        let mouseLocation = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: mouseLocation.x, y: primaryHeight - mouseLocation.y)
    }

    /// Whether the frontmost app currently has keyboard focus in an editable
    /// field. Used to re-verify the dictation target right before pasting.
    static func hasFocusedEditableElement() -> Bool {
        focusedEditability(editableRoles: editableRoles).isEditable
    }

    /// Whether the frontmost app has ANY element focused, editable or not
    /// (excluding password fields). Detection routes rather than vetoes: a
    /// focused element we can't classify is almost always a text field we failed
    /// to recognize, so a dictation still pastes there — only a truly focus-less
    /// desktop falls through to the saved list.
    static func hasAnyFocusedElement() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) != .success
            || focusedRef == nil {
            // Same Electron unlock as focusedEditability — a locked tree reads
            // as "nothing focused" and would wrongly divert the paste to a note.
            enableAssistiveTree(pid: frontApp.processIdentifier, enhanced: true)
            AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        }
        guard let focused = focusedRef else { return false }
        let element = focused as! AXUIElement
        // Never blind-paste a transcript into a password field.
        if attribute(element, kAXSubroleAttribute) as? String == "AXSecureTextField" { return false }
        return true
    }

    /// The focused editable field with enough identity to track it over time:
    /// frame (global top-left AX coords), the AX element itself, and the
    /// owning app's pid. The HUD anchors to this and dismisses the moment the
    /// element stops being the focused one — switching windows or tabs makes
    /// the pill vanish with "its" field instead of haunting the new view.
    struct FieldTarget {
        let frame: CGRect
        let element: AXUIElement
        let pid: pid_t
        /// The insertion-point rectangle (global top-left AX coords) when the app
        /// exposes it — Pages, Mail, and native text views do once their
        /// assistive tree is unlocked. Nil for AX-opaque targets.
        var caret: CGRect? = nil

        /// Whether this is the same field as `other`. Element identity is the
        /// strong signal, but WebKit (Mail's compose body) and some Electron
        /// views hand back NON-equal AXUIElement refs for the same element on
        /// every read — so `CFEqual` alone made the receipt think focus had moved
        /// each tick and hide within a beat. Fall back to geometry: same app plus
        /// a heavily-overlapping frame is the same field for our purposes.
        func isSameField(as other: FieldTarget) -> Bool {
            guard pid == other.pid else { return false }
            if CFEqual(element, other.element) { return true }
            let inter = frame.intersection(other.frame)
            guard !inter.isNull else { return false }
            let overlapArea = inter.width * inter.height
            let minArea = min(frame.width * frame.height, other.frame.width * other.frame.height)
            return minArea > 0 && overlapArea / minArea > 0.7
        }
    }

    static func focusedEditableFieldTarget() -> FieldTarget? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let focused = focusedEditability(editableRoles: editableRoles)
        guard focused.isEditable, var frame = focused.frame, let element = focused.element else {
            return nil
        }

        // Electron/web composers often report the frame of a full-width
        // WRAPPER while the visible input sits centered inside it (Claude
        // Code with vs. without a side panel shifts the content but not the
        // wrapper's left edge). The bounds of the first character — or the
        // empty-field caret — tell the truth about where text actually
        // starts, so let them correct the anchor's left edge when they land
        // sanely inside the reported frame. Honest native frames are barely
        // moved (text origin ≈ frame edge + padding).
        if let text = textOriginRect(element),
           text.minX > frame.minX + 4,
           text.minX < frame.maxX - 20,
           text.minY >= frame.minY - 8,
           text.minY <= frame.maxY + 8 {
            frame = CGRect(
                x: text.minX - 2,
                y: frame.minY,
                width: max(40, frame.maxX - text.minX),
                height: frame.height
            )
        }

        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let isRich = frontApp.bundleIdentifier.map { richEditorBundleIDs.contains($0) } ?? false
        // No follower-frame heuristics here: Google Docs' hidden input reports a
        // STATIC frame (top of the content area, tested with Chrome's full
        // accessibility tree unlocked — no range/marker/line bounds either), so
        // inferring a caret from a hidden input's frame produced a confidently
        // wrong pill. Canvas editors that expose no caret get bottom-center.
        let caret = caretRect(
            focusedElement: element,
            role: role,
            pid: frontApp.processIdentifier,
            isRichEditor: isRich,
            fieldFrame: frame
        )
        return FieldTarget(frame: frame, element: element, pid: frontApp.processIdentifier, caret: caret)
    }

    // MARK: - Field shaping signals

    /// The strings FieldProfiler needs, read from the frontmost app's focused
    /// element at insert time (focus may have moved since recording started).
    /// Named attributes on one element only — never a tree walk. Nil when
    /// nothing is focused, which shapes as `.standard`.
    static func focusedFieldShapingSignals() -> FieldShapingSignals? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef
        else { return nil }
        let element = focused as! AXUIElement
        return FieldShapingSignals(
            role: attribute(element, kAXRoleAttribute) as? String ?? "",
            subrole: attribute(element, kAXSubroleAttribute) as? String ?? "",
            roleDescription: attribute(element, kAXRoleDescriptionAttribute) as? String ?? "",
            placeholder: attribute(element, kAXPlaceholderValueAttribute) as? String ?? "",
            identifier: attribute(element, kAXIdentifierAttribute) as? String ?? "",
            label: attribute(element, kAXDescriptionAttribute) as? String ?? ""
        )
    }

    // MARK: - Caret geometry (pill rides the cursor)

    /// Apps whose full accessibility tree we've unlocked so the caret becomes
    /// readable. WebKit (Mail) and Pages only populate it once a client asks —
    /// the same signal VoiceOver sets. `true` = we also escalated to the broader
    /// AXEnhancedUserInterface flag (needed by a few native editors like Pages).
    /// main-actor–only in practice (called from the HUD tracker); the unchecked
    /// annotation keeps the shared cache off the strict-concurrency radar.
    nonisolated(unsafe) private static var assistiveTreeEnabled: [pid_t: Bool] = [:]

    private static func enableAssistiveTree(pid: pid_t, enhanced: Bool) {
        // Already at (or above) the requested level — nothing to do.
        if let escalated = assistiveTreeEnabled[pid], escalated || !enhanced { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if enhanced {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        assistiveTreeEnabled[pid] = enhanced
    }

    /// The caret rectangle for the focused editor, or nil when the app exposes
    /// none. Unlocks the app's assistive tree on first use, escalating to the
    /// broader flag only for rich editors that stay opaque under the minimal one
    /// — so most apps never get the heavier signal.
    private static func caretRect(
        focusedElement: AXUIElement,
        role: String,
        pid: pid_t,
        isRichEditor: Bool,
        fieldFrame: CGRect
    ) -> CGRect? {
        enableAssistiveTree(pid: pid, enhanced: false)
        if let r = resolveCaretRect(focusedElement, role: role, within: fieldFrame) { return r }
        if isRichEditor, assistiveTreeEnabled[pid] != true {
            enableAssistiveTree(pid: pid, enhanced: true)
            // The tree may take a beat to populate; the 4 Hz HUD tracker re-reads
            // and lands the caret on a subsequent tick.
            return resolveCaretRect(focusedElement, role: role, within: fieldFrame)
        }
        return nil
    }

    private static func resolveCaretRect(_ element: AXUIElement, role: String, within fieldFrame: CGRect) -> CGRect? {
        // Read the caret ONLY from the focused element's own insertion point.
        // A descendant search looked tempting but returned the first static-text
        // run's bounds — a fixed wrong spot that pinned the pill while the cursor
        // moved. Once the assistive tree is unlocked, focus lands on the real
        // text element (Pages → AXTextArea) whose selected-range bounds tracks
        // the caret; WebKit (Mail) exposes it via text markers instead.
        if let r = boundsForSelectedRange(element), isSaneCaret(r, within: fieldFrame) { return r }
        if let r = boundsForSelectedTextMarker(element), isSaneCaret(r, within: fieldFrame) { return r }
        // Widen coverage: some editors expose the caret's LINE but not usable
        // selected-range bounds (or return garbage for them, like Terminal).
        // The line rectangle gives the right vertical position — enough to place
        // the pill on the caret's line rather than falling to bottom-center.
        if let r = boundsForInsertionLine(element), isSaneCaret(r, within: fieldFrame) { return r }
        return nil
    }

    /// A caret must be a thin, finite rectangle sitting inside (or barely
    /// outside) the field — rejects the degenerate `(0, big) 0×0` some
    /// containers return, and selection rects that span the whole field.
    private static func isSaneCaret(_ r: CGRect, within field: CGRect) -> Bool {
        guard r.origin.x.isFinite, r.origin.y.isFinite, r.height > 1, r.height < 200 else { return false }
        if r.origin.x == 0, r.width == 0, r.height == 0 { return false }
        return field.insetBy(dx: -40, dy: -40).intersects(r)
    }

    /// Caret from an element's own selected-text range (an empty range = the
    /// insertion point; a non-empty one = the selection, whose top-left we use).
    private static func boundsForSelectedRange(_ element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeRef, &out
        ) == .success, let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((out as! AXValue), .cgRect, &rect) else { return nil }
        return rect
    }

    /// The caret's LINE rectangle, via insertion-point-line → range-for-line →
    /// bounds. A fallback for editors that expose line info but not a usable
    /// selected-range bound; gives correct vertical placement, left-aligned.
    private static func boundsForInsertionLine(_ element: AXUIElement) -> CGRect? {
        guard var line = attribute(element, kAXInsertionPointLineNumberAttribute) as? Int else { return nil }
        guard let lineNumber = CFNumberCreate(nil, .intType, &line) else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXRangeForLineParameterizedAttribute as CFString, lineNumber, &rangeRef
        ) == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeRef, &out
        ) == .success, let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((out as! AXValue), .cgRect, &rect) else { return nil }
        return rect
    }

    /// WebKit exposes the caret through text markers, not ranges — only after
    /// the assistive tree is unlocked (Mail's compose body).
    private static func boundsForSelectedTextMarker(_ element: AXUIElement) -> CGRect? {
        var markerRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRef) == .success,
              let markerRef else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, "AXBoundsForTextMarkerRange" as CFString, markerRef, &out
        ) == .success, let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((out as! AXValue), .cgRect, &rect) else { return nil }
        return rect
    }


    /// Screen bounds (global top-left coords) of the field's first character,
    /// or of the caret when the field is empty. Nil when the app doesn't
    /// implement parameterized text bounds.
    private static func textOriginRect(_ element: AXUIElement) -> CGRect? {
        let count = (attribute(element, "AXNumberOfCharacters") as? Int) ?? 0
        var range = CFRange(location: 0, length: count > 0 ? 1 : 0)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &out
        ) == .success, let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue((out as! AXValue), .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width >= 0, rect.height >= 0 else { return nil }
        return rect
    }

    /// A cheap signature of a field's content, for change detection — not the
    /// content itself. Prefers the full value; falls back to the character
    /// count, which Chromium/Electron fields (Claude's composer) expose even
    /// when they won't hand over the string. Return-to-send, edits, deletes
    /// all change it. Nil when the app exposes neither.
    struct ContentSignature: Equatable {
        let raw: String
        /// Content length — lets callers recognize an emptied field even
        /// when they never saw its full state.
        let length: Int
    }

    static func fieldContentSignature(_ element: AXUIElement) -> ContentSignature? {
        // An EMPTY value string is not a reliable signal: WebKit (Mail's compose
        // body) always reports kAXValue as "" no matter what's typed, so trusting
        // it made the receipt read "length 0" right after inserting and dismiss
        // itself as "text gone." Only a non-empty value counts; otherwise fall
        // through to the character count, then to geometry-based tracking.
        if let value = attribute(element, kAXValueAttribute) as? String, !value.isEmpty {
            return ContentSignature(raw: "v:\(value.count):\(value.hashValue)", length: value.count)
        }
        // Character count (Chromium/Electron expose this even when they won't hand
        // over the string). A count of 0 IS meaningful here — a native field going
        // empty is a send/delete we should retire the receipt on — so it's kept,
        // unlike the always-empty WebKit value string above.
        if let count = attribute(element, "AXNumberOfCharacters") as? Int {
            return ContentSignature(raw: "n:\(count)", length: count)
        }
        return nil
    }

    /// Return both the mode decision and the evidence used to make it.
    static func editabilityDecisionAtCursor() -> EditabilityDecision {
        // Check 1: is the element directly under the cursor an editable field?
        if let context = captureElementAtCursor() {
            if editableRoles.contains(context.role), context.subrole != "AXSecureTextField" {
                return EditabilityDecision(
                    isEditable: true,
                    confidence: .high,
                    summary: "editable=true source=cursor role=\(context.role) app=\(context.appName)",
                    cursorContext: context
                )
            }

            // Check parents — cursor might be on text inside an editable field
            for parent in context.parentChain {
                for role in editableRoles {
                    if parent.contains(role) {
                        return EditabilityDecision(
                            isEditable: true,
                            confidence: .high,
                            summary: "editable=true source=cursorParent role=\(context.role) parent=\(parent) app=\(context.appName)",
                            cursorContext: context
                        )
                    }
                }
            }

            // The pointer is on a real, non-editable element. The app may still
            // have an editor focused — but Slack, Notion, browsers, and terminals
            // keep one focused at ALL times, so focus alone must not force
            // dictation (it routed pointing-and-talking to the wrong mode).
            // Corroboration, either of:
            //  - the cursor is inside (or near) the focused editor's frame, or
            //  - the pointer is parked (no recent movement): dictating with the
            //    mouse out of the way is the normal case. Only a pointer the
            //    user actively moved should override keyboard focus.
            let focused = focusedEditability(editableRoles: editableRoles)
            let cursorNearFocused = focused.frame
                .map { $0.insetBy(dx: -16, dy: -16).contains(axCursorPoint()) } ?? false
            let pointerParked = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .mouseMoved
            ) > 3.0
            let isEditable = focused.isEditable && (cursorNearFocused || pointerParked)
            // No editor focused anywhere → solidly contextual. An editor IS
            // focused → every verdict here is a guess (this exact spot produced
            // both real-world misroutes), so let the transcript have the
            // final word after transcription.
            let confidence: EditabilityDecision.Confidence =
                (focused.isEditable && !cursorNearFocused) ? .low : .high
            return EditabilityDecision(
                isEditable: isEditable,
                confidence: confidence,
                summary: "editable=\(isEditable) confidence=\(confidence.rawValue) source=focusedFallback cursorRole=\(context.role) cursorApp=\(context.appName) cursorInFocusedFrame=\(cursorNearFocused) pointerParked=\(pointerParked) \(focused.summary)",
                cursorContext: context
            )
        }

        // Check 2: AX cannot resolve the element under the pointer at all — fall
        // back to the app's focused element. Cursor evidence is absent here, so
        // only demote when we positively know the cursor is far from the editor.
        let focused = focusedEditability(editableRoles: editableRoles)
        let cursorNearFocused = focused.frame
            .map { $0.insetBy(dx: -16, dy: -16).contains(axCursorPoint()) } ?? true
        let isEditable = focused.isEditable && cursorNearFocused
        return EditabilityDecision(
            isEditable: isEditable,
            confidence: focused.isEditable ? .low : .high,
            summary: "editable=\(isEditable) source=focusedOnly cursorInFocusedFrame=\(cursorNearFocused) \(focused.summary)",
            cursorContext: nil
        )
    }

    private static func focusedEditability(editableRoles: Set<String>) -> FocusedEditability {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return FocusedEditability(isEditable: false, summary: "focused=none app=none", frame: nil)
        }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) != .success
            || focusedRef == nil {
            // Electron apps (VS Code, Cursor) expose NO tree — not even a focused
            // element — until the assistive flags are set, and unlike Pages-class
            // apps they need the stronger AXEnhancedUserInterface. "The app claims
            // nothing is focused at all" is precisely the case where escalating
            // can't hurt and is the only thing that helps: unlock and re-read.
            enableAssistiveTree(pid: frontApp.processIdentifier, enhanced: true)
            AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        }
        guard let focused = focusedRef else {
            return FocusedEditability(
                isEditable: false,
                summary: "focused=none app=\(frontApp.localizedName ?? "unknown")",
                frame: nil
            )
        }

        let focusedElement = focused as! AXUIElement
        let role = attribute(focusedElement, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(focusedElement, kAXSubroleAttribute) as? String ?? ""
        let roleDescription = attribute(focusedElement, kAXRoleDescriptionAttribute) as? String ?? ""
        let focusedSummary = "focusedRole=\(role.isEmpty ? "none" : role) subrole=\(subrole.isEmpty ? "none" : subrole) desc=\(roleDescription.isEmpty ? "none" : roleDescription) app=\(frontApp.localizedName ?? "unknown")"

        // Never route dictation into a password field — the transcript would be
        // pasted into it and briefly sit on the clipboard.
        if subrole == "AXSecureTextField" {
            return FocusedEditability(isEditable: false, summary: focusedSummary + " secureField=true", frame: nil)
        }

        // Disabled/read-only fields swallow the paste and the transcript is lost.
        if let enabled = attribute(focusedElement, kAXEnabledAttribute) as? Bool, !enabled {
            return FocusedEditability(isEditable: false, summary: focusedSummary + " enabled=false", frame: nil)
        }

        let frame = elementFrame(focusedElement)

        // Direct role match on focused element
        if editableRoles.contains(role) {
            return FocusedEditability(isEditable: true, summary: focusedSummary, frame: frame, element: focusedElement)
        }

        // Web/Electron editors: check subrole and text-editing affordances.
        if subrole == "AXContentEditable" || subrole == "AXPlainText" {
            return FocusedEditability(isEditable: true, summary: focusedSummary, frame: frame, element: focusedElement)
        }

        // Toolkit-agnostic signal: a focused element that exposes a text caret
        // (AXSelectedTextRange — a CHARACTER range, distinct from a row/child
        // selection) is a text editor, whatever its role or app — across
        // AppKit and Electron, without a per-app allowlist. ONE measured
        // exception: browsers keep a document-level selection range on every
        // page, editable or not, so a bare AXWebArea "has a caret" even on a
        // read-only article (Chrome: focusedRole=AXWebArea subrole=none
        // desc="HTML content" textCaret=true, typed instead of saved). Web
        // areas fall through to the stricter checks below — a truly editable
        // one (Mail's compose body) still passes via valueSettable, and web
        // page editors focus a contenteditable or field, caught earlier.
        if role != "AXWebArea", hasTextCaret(focusedElement) {
            return FocusedEditability(
                isEditable: true,
                summary: focusedSummary + " textCaret=true",
                frame: frame,
                element: focusedElement
            )
        }

        if isLikelyEditableTextElement(focusedElement, role: role, subrole: subrole) {
            return FocusedEditability(isEditable: true, summary: focusedSummary, frame: frame, element: focusedElement)
        }

        // A focused element with a SETTABLE value is a text sink even when it
        // advertises nothing else — Mail's compose body focuses an AXWebArea
        // ("HTML content") whose only editable tell is valueSettable=true. This
        // check is safe here because we only reach it via keyboard focus (the
        // ambiguous mouse-hover path resolves earlier); a focused, settable,
        // non-secure, enabled element accepts pasted text.
        var valueSettable: DarwinBoolean = false
        if textContainerRoles.contains(role),
           AXUIElementIsAttributeSettable(focusedElement, kAXValueAttribute as CFString, &valueSettable) == .success,
           valueSettable.boolValue {
            return FocusedEditability(
                isEditable: true,
                summary: focusedSummary + " valueSettable=true",
                frame: frame,
                element: focusedElement
            )
        }

        // AX-opaque rich editors (Pages et al.) expose no signal at all on their
        // focused canvas. Recognize them by app identity, but only when a
        // plausible text container holds focus — never a button/inspector.
        if let bundleID = frontApp.bundleIdentifier,
           richEditorBundleIDs.contains(bundleID),
           textContainerRoles.contains(role) {
            return FocusedEditability(
                isEditable: true,
                summary: focusedSummary + " richEditorApp=\(bundleID)",
                frame: frame,
                element: focusedElement
            )
        }

        // Check 3: walk up from focused element looking for editable containers
        var current = focusedElement
        var parentRoles: [String] = []
        for _ in 0..<3 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { break }
            let parentElement = parent as! AXUIElement
            let parentRole = attribute(parentElement, kAXRoleAttribute) as? String ?? ""
            parentRoles.append(parentRole)
            if editableRoles.contains(parentRole) {
                return FocusedEditability(
                    isEditable: true,
                    summary: "\(focusedSummary) focusedParent=\(parentRole)",
                    frame: elementFrame(parentElement) ?? frame,
                    element: parentElement
                )
            }
            current = parentElement
        }

        let parentSummary = parentRoles.isEmpty ? "" : " focusedParents=\(parentRoles.joined(separator: ">"))"
        return FocusedEditability(isEditable: false, summary: focusedSummary + parentSummary, frame: nil)
    }

    /// Element frame in global top-left coordinates (same space as AX hit-testing).
    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pos = posRef, let size = sizeRef,
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue((pos as! AXValue), .cgPoint, &point),
              AXValueGetValue((size as! AXValue), .cgSize, &dimensions) else { return nil }
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func isLikelyEditableTextElement(
        _ element: AXUIElement,
        role: String,
        subrole: String
    ) -> Bool {
        let roleDescription = (attribute(element, kAXRoleDescriptionAttribute) as? String ?? "").lowercased()
        let roleText = role.lowercased()
        let subroleText = subrole.lowercased()

        let hasExplicitEditableIdentity =
            subrole == "AXContentEditable" ||
            subrole == "AXPlainText" ||
            subroleText.contains("editable") ||
            roleDescription.contains("text field") ||
            roleDescription.contains("text area") ||
            roleDescription.contains("editable text")

        let hasTextIdentity = hasExplicitEditableIdentity ||
                              roleText.contains("text") ||
                              subroleText.contains("text") ||
                              roleDescription.contains("text") ||
                              roleDescription.contains("edit")

        let textEditingAttributes = [
            kAXSelectedTextAttribute,
            kAXSelectedTextRangeAttribute,
            kAXInsertionPointLineNumberAttribute,
            "AXNumberOfCharacters"
        ]
        var hasTextEditingAttribute = false
        for attr in textEditingAttributes {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success {
                hasTextEditingAttribute = true
                break
            }
        }

        var isSettable: DarwinBoolean = false
        let valueIsSettable =
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isSettable) == .success &&
            isSettable.boolValue

        // Many web/Electron apps expose generic AXGroup/AXWebArea elements with
        // selection-like attributes. Treat those as editable only when the AX
        // metadata explicitly says the element is text/editable; otherwise
        // contextual captures get misclassified as dictation.
        let genericContainerRoles: Set<String> = [
            "AXGroup", "AXWebArea", "AXScrollArea", "AXWindow", "AXApplication"
        ]
        if genericContainerRoles.contains(role) {
            return hasExplicitEditableIdentity && (hasTextEditingAttribute || valueIsSettable)
        }

        return hasTextIdentity && (hasTextEditingAttribute || valueIsSettable)
    }

    /// Capture element info at the current cursor position.
    /// Returns nil if accessibility access is denied or no element found.
    static func captureElementAtCursor() -> ElementContext? {
        // Convert to AX screen coordinates (top-left origin, primary screen)
        let point = axCursorPoint()

        // Get the element at the cursor position
        let systemWide = AXUIElementCreateSystemWide()
        var axElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &axElement)

        guard result == .success, let element = axElement else { return nil }

        // Extract attributes
        let role = attribute(element, kAXRoleAttribute) as? String ?? "Unknown"
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        let title = attribute(element, kAXTitleAttribute) as? String
        let value = attribute(element, kAXValueAttribute) as? String
        let roleDesc = attribute(element, kAXRoleDescriptionAttribute) as? String
        let label = attribute(element, kAXDescriptionAttribute) as? String
        let identifier = attribute(element, kAXIdentifierAttribute) as? String

        // Walk up parent chain for context (max 5 levels)
        // Also extract the window title from the AXWindow parent
        var parentChain: [String] = []
        var windowTitle: String?
        var current: AXUIElement? = element
        for _ in 0..<5 {
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current!, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { break }
            let parentElement = parent as! AXUIElement
            let parentRole = attribute(parentElement, kAXRoleAttribute) as? String
            let parentTitle = attribute(parentElement, kAXTitleAttribute) as? String

            // Capture the window title from the AXWindow parent
            if parentRole == "AXWindow", let parentTitle, !parentTitle.isEmpty {
                windowTitle = parentTitle
            }

            var desc = parentRole ?? "?"
            if let parentTitle, !parentTitle.isEmpty { desc += " \"\(parentTitle.prefix(30))\"" }
            parentChain.append(desc)
            current = parentElement
        }

        // Get the app that owns the element under the cursor (not the frontmost app).
        // This correctly attributes elements to their owning app even when another app is in front.
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let appName: String
        if pid != 0, let ownerApp = NSRunningApplication(processIdentifier: pid) {
            appName = ownerApp.localizedName ?? "Unknown"
        } else {
            appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        }

        return ElementContext(
            role: role,
            subrole: subrole,
            title: title,
            value: value,
            roleDescription: roleDesc,
            label: label,
            identifier: identifier,
            parentChain: parentChain,
            appName: appName,
            windowTitle: windowTitle
        )
    }

    private static func attribute(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        return value
    }

    /// Whether the element exposes a text insertion point — a character-range
    /// selection or an insertion-point line. Both are text-only attributes, so
    /// their presence marks the element as a real text editor.
    private static func hasTextCaret(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXValueGetTypeID() {
            return true
        }
        if AXUIElementCopyAttributeValue(element, kAXInsertionPointLineNumberAttribute as CFString, &value) == .success,
           value != nil {
            return true
        }
        return false
    }
}
