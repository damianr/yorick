import XCTest

final class VocabularyCorrectorTests: XCTestCase {

    private func apply(_ text: String, _ entries: [VocabularyEntry]) -> String {
        VocabularyCorrector.apply(text, entries: entries)
    }

    func testHeardAsIsSwappedForTheTerm() {
        let waits = VocabularyEntry(term: "Waits", heardAs: ["weights"])
        XCTAssertEqual(apply("Tell weights dinner is ready.", [waits]), "Tell Waits dinner is ready.")
        XCTAssertEqual(apply("Weights, come here!", [waits]), "Waits, come here!")
        XCTAssertEqual(apply("weights's homework", [waits]), "Waits's homework")
    }

    func testHeardAsMatchesWholeWordsOnly() {
        let waits = VocabularyEntry(term: "Waits", heardAs: ["weights"])
        XCTAssertEqual(apply("paperweights and lightweights", [waits]), "paperweights and lightweights")
    }

    func testMultiWordHeardAs() {
        let entry = VocabularyEntry(term: "Supabase", heardAs: ["super base"])
        XCTAssertEqual(apply("store it in super  base tonight", [entry]), "store it in Supabase tonight")
    }

    func testCamelCaseTermsJoinTheirSpokenHumps() {
        let entry = VocabularyEntry(term: "InfuseFlow")
        XCTAssertEqual(apply("open infuse flow and check", [entry]), "open InfuseFlow and check")
        XCTAssertEqual(VocabularyCorrector.spacedForm(of: "SwiftUI"), "swift ui")
        XCTAssertEqual(VocabularyCorrector.spacedForm(of: "XMLParser"), "xml parser")
        XCTAssertNil(VocabularyCorrector.spacedForm(of: "Yorick"))
    }

    func testDeliberateCasingIsRestored() {
        let entry = VocabularyEntry(term: "SwiftUI")
        XCTAssertEqual(apply("we use swiftui here", [entry]), "we use SwiftUI here")
    }

    func testPlainCapitalizedTermNeverRecasesCommonWords() {
        // "Waits" with no heard-as must leave the verb alone.
        let waits = VocabularyEntry(term: "Waits")
        XCTAssertEqual(apply("she waits for the bus", [waits]), "she waits for the bus")
    }

    func testEmptyVocabularyIsIdentity() {
        XCTAssertEqual(apply("nothing to change", []), "nothing to change")
    }
}

final class CorrectionLearnerTests: XCTestCase {

    private func suggest(_ typed: String, _ current: String) -> [VocabularySuggestion]? {
        CorrectionLearner.suggestions(typed: typed, current: current)
    }

    func testSoundAlikeNameFixIsSuggested() {
        XCTAssertEqual(
            suggest("Tell weights dinner is ready.", "Hey there. Tell Waits dinner is ready."),
            [VocabularySuggestion(heard: "weights", term: "Waits")]
        )
        XCTAssertEqual(
            suggest("ask cloud to review the code", "ask Claude to review the code"),
            [VocabularySuggestion(heard: "cloud", term: "Claude")]
        )
    }

    func testJoinedCamelCaseFixIsSuggested() {
        XCTAssertEqual(
            suggest("we should use infuse flow for this", "we should use InfuseFlow for this"),
            [VocabularySuggestion(heard: "infuse flow", term: "InfuseFlow")]
        )
    }

    func testDeliberateCasingFixIsSuggested() {
        XCTAssertEqual(
            suggest("we use swiftui here", "we use SwiftUI here"),
            [VocabularySuggestion(heard: "swiftui", term: "SwiftUI")]
        )
    }

    func testGrammarFixesStayQuiet() {
        XCTAssertEqual(suggest("their going to the store", "there going to the store"), [])
    }

    func testRewordingStaysQuiet() {
        // Different name, not a sound-alike.
        XCTAssertEqual(suggest("send it to bob tomorrow", "send it to Robert tomorrow"), [])
        // Pure insertion.
        XCTAssertEqual(suggest("I lift weights daily", "I lift heavy weights daily"), [])
    }

    func testHalfTypedFixStaysQuiet() {
        XCTAssertEqual(suggest("I talked to weights", "I talked to Wai"), [])
    }

    func testGoneTextIsNil() {
        XCTAssertNil(suggest("this is a totally different sentence", "nothing in common at all here"))
        XCTAssertNil(suggest("hello there friend", ""))
    }

    func testSoundsAlike() {
        XCTAssertTrue(CorrectionLearner.soundsAlike("weights", "Waits"))
        XCTAssertTrue(CorrectionLearner.soundsAlike("codex", "Codecs"))
        XCTAssertTrue(CorrectionLearner.soundsAlike("supa base", "Supabase"))
        XCTAssertFalse(CorrectionLearner.soundsAlike("bob", "Robert"))
    }
}
