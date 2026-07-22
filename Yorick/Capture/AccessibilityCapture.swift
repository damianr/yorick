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

    /// The focused editable field with enough identity to track it over time:
    /// frame (global top-left AX coords), the AX element itself, and the
    /// owning app's pid. The HUD anchors to this and dismisses the moment the
    /// element stops being the focused one — switching windows or tabs makes
    /// the pill vanish with "its" field instead of haunting the new view.
    struct FieldTarget {
        let frame: CGRect
        let element: AXUIElement
        let pid: pid_t

        /// Same identity (element + app), regardless of geometry.
        func isSameField(as other: FieldTarget) -> Bool {
            pid == other.pid && CFEqual(element, other.element)
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

        return FieldTarget(frame: frame, element: element, pid: frontApp.processIdentifier)
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
        if let value = attribute(element, kAXValueAttribute) as? String {
            return ContentSignature(raw: "v:\(value.count):\(value.hashValue)", length: value.count)
        }
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
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
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

        if isLikelyEditableTextElement(focusedElement, role: role, subrole: subrole) {
            return FocusedEditability(isEditable: true, summary: focusedSummary, frame: frame, element: focusedElement)
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
}
