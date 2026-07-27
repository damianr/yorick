import Foundation

/// The editability ladder as a PURE function — the routing brain, separated
/// from the AX plumbing that feeds it.
///
/// Every rung here was shaped by a real-world misroute, and each one is
/// pinned by a fixture in FocusClassifierTests built from actual field
/// diagnostics. That suite is the regression net this heuristic never had:
/// browsers, Electron shells, and rich editors keep inventing new ways to
/// look editable (or hide that they are), so the ladder gets corrected at
/// its edges regularly — and an untested correction fixes one app while
/// silently re-breaking another. Change a rung, add its fixture.
enum FocusClassifier {

    /// Roles that ARE text editors, full stop.
    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"
    ]

    /// Rich editors whose focused canvas is AX-opaque: no editable role, no
    /// settable value, no readable text attributes (verified via AX probe —
    /// Pages focuses a bare AXScrollArea, Word/Keynote similar). A ⌘V paste
    /// still lands, so app identity is trusted when a plausible text
    /// container holds focus.
    static let richEditorBundleIDs: Set<String> = [
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

    /// Roles that can plausibly hold a text cursor in a rich editor. Guards
    /// the bundle-ID trust path so a focused button/slider/menu in Pages is
    /// never mistaken for the document canvas.
    static let textContainerRoles: Set<String> = [
        "AXScrollArea", "AXTextArea", "AXTextField", "AXWebArea",
        "AXGroup", "AXLayoutArea", "AXUnknown"
    ]

    /// What the ladder consults. Signals that cost an AX round-trip are
    /// closures, so the live path keeps its short-circuit latency and
    /// fixtures pass constants.
    struct Signals {
        var role = ""
        var subrole = ""
        var isEnabled = true
        var isRichEditorApp = false
        var richEditorBundleID: String?
        var hasTextCaret: () -> Bool = { false }
        var isLikelyEditableText: () -> Bool = { false }
        var valueSettable: () -> Bool = { false }
    }

    /// A decided verdict, or nil when the ladder is exhausted — the caller
    /// then walks parents (the final rung) and defaults to not-editable.
    /// `tag` keeps the exact legacy diagnostic tokens so field logs stay
    /// greppable across the refactor.
    static func classify(_ s: Signals) -> (editable: Bool, tag: String)? {
        // Never route dictation into a password field — the transcript
        // would be pasted into it and briefly sit on the clipboard.
        if s.subrole == "AXSecureTextField" { return (false, " secureField=true") }

        // Disabled/read-only fields swallow the paste; the words are lost.
        if !s.isEnabled { return (false, " enabled=false") }

        // Direct role match.
        if editableRoles.contains(s.role) { return (true, "") }

        // Web/Electron editors advertising editability by subrole.
        if s.subrole == "AXContentEditable" || s.subrole == "AXPlainText" { return (true, "") }

        // Toolkit-agnostic caret signal (AXSelectedTextRange — a CHARACTER
        // range). Two measured exceptions where a document-level selection
        // masquerades as a caret on read-only content: bare AXWebArea
        // (Chrome pages typed into nothing) and bare AXGroup (the Claude
        // app's Electron preview pane, same failure). Real editors behind
        // those shells focus a text role or contenteditable, caught above;
        // truly editable web areas (Mail compose) pass via settable below.
        // The asymmetry decides close calls: wrongly saving costs one Copy
        // click, wrongly typing swallows the paste invisibly.
        if s.role != "AXWebArea", s.role != "AXGroup", s.hasTextCaret() { return (true, " textCaret=true") }

        // Text-editing affordances short of a caret.
        if s.isLikelyEditableText() { return (true, " likelyText=true") }

        // A focused text container with a SETTABLE value is a text sink even
        // when it advertises nothing else — Mail's compose body is exactly
        // this. Safe here because only keyboard focus reaches this ladder.
        if textContainerRoles.contains(s.role), s.valueSettable() { return (true, " valueSettable=true") }

        // AX-opaque rich editors, trusted by app identity + container role.
        if s.isRichEditorApp, textContainerRoles.contains(s.role) {
            return (true, " richEditorApp=\(s.richEditorBundleID ?? "?")")
        }

        return nil
    }
}
