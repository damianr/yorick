import XCTest

/// Deterministic title assembly, pinned. Every case here came from a real
/// miss or from the strategy eval, so a future "simplification" that breaks
/// one of them fails loudly instead of quietly getting worse.
final class TitleComposerTests: XCTestCase {

    private func input(
        _ transcript: String, source: String = "Notes",
        windowTitle: String = "", facts: [ContextFact] = []
    ) -> IssueComposer.Input {
        IssueComposer.Input(
            transcript: transcript, sourceLine: source, windowTitle: windowTitle,
            context: facts.isEmpty ? nil : CaptureContext(facts: facts)
        )
    }

    private func pointed(_ value: String, _ detail: String) -> ContextFact {
        ContextFact(kind: "pointedElement", value: value, detail: detail, phase: "timeline")
    }

    // MARK: Scaffolding

    func testFirstPersonOpenersAreStripped() {
        XCTAssertEqual(
            TitleComposer.predicate(from: "I want to de-emphasize this section here"),
            "De-emphasize this section here"
        )
        XCTAssertEqual(
            TitleComposer.predicate(from: "maybe we should look at the settings gear"),
            "Look at the settings gear"
        )
    }

    /// The opener has to end on a word boundary or "so" eats "software".
    func testOpenerMatchingRespectsWordBoundaries() {
        XCTAssertEqual(
            TitleComposer.predicate(from: "software updates are broken"),
            "Software updates are broken"
        )
    }

    /// A COMMA is a boundary too: "yeah so the thing is, um, …" is how people
    /// actually talk, and matching only a space left the whole preamble in.
    func testOpenersFollowedByCommasAreStripped() {
        let title = TitleComposer.predicate(
            from: "yeah so the thing is, um, I feel like the onboarding copy is too long"
        )
        XCTAssertFalse(title.lowercased().hasPrefix("yeah"))
        XCTAssertTrue(title.lowercased().contains("onboarding copy"))
    }

    /// Ordering hazard, found by measurement: truncating at the first comma
    /// BEFORE peeling openers reduced this to the scaffolding alone, which
    /// then peeled to nothing.
    func testClauseTruncationHappensAfterOpenersArePeeled() {
        let title = TitleComposer.predicate(
            from: "okay so the thing is the changelog page, nobody has touched it since March "
                + "and it is starting to look abandoned"
        )
        XCTAssertTrue(title.lowercased().contains("changelog"))
        XCTAssertLessThanOrEqual(title.count, 80)
    }

    func testNothingIsInventedByThePredicate() {
        let transcript = "the export button throws when the list is empty"
        let title = TitleComposer.predicate(from: transcript)
        // Subtractive only: every word must have been spoken.
        let spoken = Set(transcript.lowercased().components(separatedBy: " "))
        for word in title.lowercased().components(separatedBy: " ") where !word.isEmpty {
            XCTAssertTrue(spoken.contains(word), "\(word) was never said")
        }
    }

    // MARK: Subjects

    func testHeadingIsParsedOutOfAPointedDetail() {
        XCTAssertEqual(
            TitleComposer.headingFromDetail("text, under “Optional cleanup”"),
            "Optional cleanup"
        )
        XCTAssertNil(TitleComposer.headingFromDetail("row"))
    }

    /// A heading beats the paragraph under it, which beats the page.
    func testSubjectsAreRankedByHowWellTheyName() {
        let subjects = TitleComposer.subjects(input(
            "this is wrong",
            windowTitle: "Yorick — Google Chrome",
            facts: [pointed("Ums and false starts come out first.", "text, under “Optional cleanup”")]
        ))
        XCTAssertEqual(subjects.first?.text, "Optional cleanup")
        XCTAssertEqual(subjects.first?.provenance, "heading")
    }

    /// Framed text outranks the pointed element: drawing a box is deliberate,
    /// and wherever the mouse happened to rest is not.
    func testScreenshotTextOutranksThePointedElement() {
        let subjects = TitleComposer.subjects(
            input("wrong colour", facts: [pointed("Primary button", "layer")]),
            screenshotText: ["Checkout Flow"]
        )
        XCTAssertEqual(subjects.first?.text, "Checkout Flow")
    }

    func testParagraphsAreNotNames() {
        XCTAssertFalse(TitleComposer.isNameLike(String(repeating: "long ", count: 30)))
        XCTAssertTrue(TitleComposer.isNameLike("Optional cleanup"))
    }

    // MARK: Assembly

    func testDemonstrativeGetsTheSubjectPrefixed() {
        let title = TitleComposer.deterministicTitle(input(
            "I want to de-emphasize this section here",
            source: "Chrome · heyyorick.com",
            facts: [pointed("Ums and false starts.", "text, under “Optional cleanup”")]
        ))
        XCTAssertEqual(title, "Optional cleanup — de-emphasize this section here")
    }

    /// A predicate that names its own subject must not get a prefix — "The
    /// saved list needs an empty state" says it already.
    func testSelfNamingPredicateIsLeftAlone() {
        let title = TitleComposer.deterministicTitle(input(
            "I think the saved list needs an empty state",
            source: "Xcode · MenuBarPanelView.swift"
        ))
        XCTAssertEqual(title, "The saved list needs an empty state")
    }

    /// "Wrong colour" has no demonstrative but cannot stand alone either.
    func testTersePredicateTakesAStrongSubject() {
        let title = TitleComposer.deterministicTitle(input(
            "wrong colour", source: "Figma",
            facts: [pointed("Primary button", "layer, under “Buttons”")]
        ))
        XCTAssertTrue(title.contains("Buttons"))
        XCTAssertTrue(title.lowercased().contains("wrong colour"))
    }

    /// …but a WEAK subject is not worth prefixing to a terse predicate. "The
    /// appcast is stale" beats "Terminal — the appcast is stale".
    func testTersePredicateRefusesAWeakSubject() {
        let title = TitleComposer.deterministicTitle(input("the appcast is stale", source: "Terminal"))
        XCTAssertEqual(title, "The appcast is stale")
    }

    func testTitlesStayScannable() {
        let title = TitleComposer.deterministicTitle(input(
            String(repeating: "the interface is cluttered and confusing ", count: 6)
        ))
        XCTAssertLessThanOrEqual(title.count, 90)
    }
}
