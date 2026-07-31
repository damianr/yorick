import XCTest

/// The regression net for the routing brain. Every fixture is a REAL field
/// diagnosis (capture diagnostics quoted where they exist) — when a new
/// misroute is found and fixed, its signal-set gets added here so the next
/// edge correction can't silently re-break it.
final class FocusClassifierTests: XCTestCase {

    private func classify(
        role: String = "",
        subrole: String = "",
        enabled: Bool = true,
        explicitIdentity: Bool = false,
        settable: Bool = false,
        richEditor: String? = nil
    ) -> (editable: Bool, tag: String)? {
        FocusClassifier.classify(FocusClassifier.Signals(
            role: role,
            subrole: subrole,
            isEnabled: enabled,
            bundleID: richEditor,
            hasExplicitEditableIdentity: { explicitIdentity },
            valueSettable: { settable }
        ))
    }

    // MARK: - Plain editors type

    func testDirectRolesAreEditable() {
        // TextEdit document, ChatGPT's Electron composer, Google Docs'
        // hidden input: all focus a real text role.
        XCTAssertEqual(classify(role: "AXTextArea")?.editable, true)
        XCTAssertEqual(classify(role: "AXTextField")?.editable, true)
        // Chrome omnibox (field detection: routing types; only its CARET is
        // unreadable, which is placement's problem, not routing's).
        XCTAssertEqual(classify(role: "AXTextField", subrole: "AXSearchField")?.editable, true)
    }

    func testContentEditableSubrolesAreEditable() {
        // Slack/Notion-class web editors: contenteditable inside a shell.
        XCTAssertEqual(classify(role: "AXGroup", subrole: "AXContentEditable")?.editable, true)
        XCTAssertEqual(classify(role: "AXWebArea", subrole: "AXPlainText")?.editable, true)
    }

    func testExplicitIdentityIsEditable() {
        // A custom role whose AX metadata SAYS "text field"/"editable" —
        // identity claims are the only heuristic net left, by design.
        XCTAssertEqual(classify(role: "AXUnknown", explicitIdentity: true)?.tag, " explicitTextIdentity=true")
    }

    // MARK: - The selection-range masquerade (all three measured in the
    // field; the caret rung they exploited is DELETED — these fixtures now
    // pin that selection ranges are never evidence of editability)

    func testChromeReadOnlyPageIsUndecided() {
        // Field diagnosis: "focusedRole=AXWebArea subrole=none desc=HTML
        // content textCaret=true" on a read-only page — typed into nothing.
        // Browsers keep a document-level selection range on EVERY page.
        XCTAssertNil(classify(role: "AXWebArea"))
    }

    func testClaudePreviewPaneIsUndecided() {
        // Field diagnosis: "focusedRole=AXGroup desc=group textCaret=true"
        // — the Claude app's Electron preview swallowed the paste.
        XCTAssertNil(classify(role: "AXGroup"))
    }

    func testSelectableStaticTextIsUndecided() {
        // Field diagnosis: "focusedRole=AXStaticText desc=text app=Yorick
        // textCaret=true" — SwiftUI selectable text in Yorick's own list
        // routed dictation into itself. Static text is read-only by
        // contract, whatever selection range it carries.
        XCTAssertNil(classify(role: "AXStaticText"))
    }

    func testSelectStyleComboBoxIsUndecided() {
        // Field diagnosis: clicking a dropdown mid-recording anchored the
        // pill and pasted the transcript into its type-to-search. Combos
        // take keystrokes but not free text; genuinely editable combos
        // focus their inner AXTextField, which still matches directly.
        XCTAssertNil(classify(role: "AXComboBox"))
    }

    func testMailComposeStillTypes() {
        // Mail's compose body: an AXWebArea whose ONLY editable tell is the
        // settable value.
        XCTAssertEqual(classify(role: "AXWebArea", settable: true)?.tag, " valueSettable=true")
    }

    // MARK: - Hard vetoes

    func testSecureFieldNeverTypes() {
        // Password fields: transcript on the clipboard is the harm; wins
        // over every editable signal.
        let v = classify(role: "AXTextField", subrole: "AXSecureTextField", explicitIdentity: true, settable: true)
        XCTAssertEqual(v?.editable, false)
        XCTAssertEqual(v?.tag, " secureField=true")
    }

    func testDisabledFieldNeverTypes() {
        // Disabled fields swallow the paste; the words are lost.
        XCTAssertEqual(classify(role: "AXTextField", enabled: false)?.editable, false)
    }

    // MARK: - AX-opaque rich editors

    func testPagesCanvasTypesViaAppIdentity() {
        // Pages focuses a bare AXScrollArea with no signal at all; app
        // identity + container role is the trust path.
        let v = classify(role: "AXScrollArea", richEditor: "com.apple.iWork.Pages")
        XCTAssertEqual(v?.editable, true)
        XCTAssertTrue(v?.tag.contains("richEditorApp") ?? false)
    }

    func testRichEditorButtonIsNotACanvas() {
        // A focused button in Pages must never read as the document.
        XCTAssertNil(classify(role: "AXButton", richEditor: "com.apple.iWork.Pages"))
    }

    // MARK: - Exhausted ladder

    func testBareGroupWithNoSignalsIsUndecided() {
        // Undecided → caller walks parents, then defaults to save. Safe
        // either way: every transcript persists to the list regardless.
        XCTAssertNil(classify(role: "AXGroup"))
    }
}
