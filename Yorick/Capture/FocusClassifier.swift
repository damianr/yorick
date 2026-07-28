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

    /// Roles that accept FREE TEXT, full stop. AXComboBox was removed
    /// (founder-directed rigidity): select-style combos took type-to-search
    /// keystrokes, so a mid-recording click on a dropdown anchored the pill
    /// and pasted a transcript into it. Genuinely editable combos focus
    /// their inner AXTextField while editing, which still matches.
    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField"
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
        var hasExplicitEditableIdentity: () -> Bool = { false }
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

        // NO caret rung, deliberately. It existed as a toolkit-agnostic net
        // ("a focused element with AXSelectedTextRange is an editor") and
        // went 0-for-3 in the field — every actual hit was a selection
        // range masquerading on read-only content: Chrome pages, the Claude
        // app's Electron preview pane, and SwiftUI selectable text in
        // Yorick's own list. Selection-range attributes are NEVER evidence
        // of editability again; the ladder's contract is rigid — only
        // surfaces that accept free text type, everything doubtful saves,
        // and a wrong save costs one Copy click while a wrong type swallows
        // the paste invisibly.

        // Explicit editable identity: the element SAYS it's a text editor
        // (an "editable" subrole variant, or a role description of "text
        // field"/"text area"/"editable text"). Identity claims only — no
        // attribute sniffing.
        if s.hasExplicitEditableIdentity() { return (true, " explicitTextIdentity=true") }

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
