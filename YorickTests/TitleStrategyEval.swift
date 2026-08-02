import XCTest

/// Four ways to build an issue title, measured against the same corpus.
///
/// Written because two prompt attempts produced two different failure modes
/// — one lifted a sentence verbatim, one wrote something confidently wrong —
/// and arguing about a third prompt is not evidence. Each strategy runs over
/// every case; the table at the end is the answer.
///
///   TEST_RUNNER_YORICK_EVAL=1 xcodebuild … \
///     -only-testing:YorickTests/TitleStrategyEval
final class TitleStrategyEval: XCTestCase {

    private struct Case {
        let name: String
        let transcript: String
        let source: String
        let windowTitle: String
        let facts: [ContextFact]
        /// Lowercased fragments the title must contain to be USEFUL — almost
        /// always the subject. A title without one of these is the failure
        /// being chased: "I don't really need this section" names nothing.
        let mustName: [String]
        /// Text that would mean the title inverted or fabricated the meaning.
        let mustNotContain: [String]

        init(_ name: String, _ transcript: String, source: String, windowTitle: String = "",
             facts: [ContextFact] = [], names: [String], avoids: [String] = []) {
            self.name = name
            self.transcript = transcript
            self.source = source
            self.windowTitle = windowTitle
            self.facts = facts
            self.mustName = names
            self.mustNotContain = avoids
        }

        var input: IssueComposer.Input {
            IssueComposer.Input(
                transcript: transcript,
                sourceLine: source,
                windowTitle: windowTitle,
                context: facts.isEmpty ? nil : CaptureContext(facts: facts)
            )
        }
    }

    private static func pointed(_ value: String, _ detail: String) -> ContextFact {
        ContextFact(kind: "pointedElement", value: value, detail: detail, phase: "timeline")
    }
    private static func selection(_ value: String) -> ContextFact {
        ContextFact(kind: "selection", value: value, detail: "AXTextArea", phase: "start")
    }
    private static func page(_ url: String) -> ContextFact {
        ContextFact(kind: "pageURL", value: url, detail: nil, phase: "start")
    }

    /// Openers that mean a sentence was lifted rather than a title written.
    private static let speechOpeners = [
        "i ", "i'", "we ", "we'", "this ", "that ", "maybe ", "so ", "uh ", "yeah ", "okay ", "um ",
    ]

    // MARK: - Corpus

    private static let cases: [Case] = [
        // ---- The real field miss that started this ----
        .init("field: de-emphasize a section",
              "I want to de-emphasize this section here. Uh, I just don't know that we "
              + "really need it. Maybe we can come up with something else that goes there.",
              source: "Chrome · heyyorick.com",
              windowTitle: "Yorick: you talk, it types. - Google Chrome - damian",
              facts: [page("https://heyyorick.com/"),
                      pointed("Ums and false starts come out before the text is typed.",
                              "text, under “Optional cleanup”"),
                      pointed("Optional cleanup", "text")],
              names: ["optional cleanup"], avoids: ["emphasize ums"]),

        // ---- Pure demonstratives: the subject exists ONLY in context ----
        .init("this number is wrong",
              "this number is wrong",
              source: "Chrome · Odds dashboard",
              facts: [pointed("Lakers · -110 · implied 52.4%", "row")],
              names: ["lakers"]),

        .init("these need to be consistent",
              "these need to be consistent, half of them say one thing and half say the other",
              source: "Xcode · PreferencesView.swift",
              facts: [selection("Clean up dictation before it types")],
              names: ["clean up dictation"]),

        .init("this whole section is too long",
              "this whole section is way too long, nobody's getting past the first line",
              source: "Chrome · heyyorick.com",
              facts: [page("https://heyyorick.com/"),
                      pointed("Nothing you say is lost", "paragraph, under “Nothing's lost”")],
              names: ["nothing's lost"]),

        .init("move this up",
              "we should probably move this up, it gets lost down there",
              source: "Chrome · heyyorick.com",
              facts: [pointed("Download for macOS", "link")],
              names: ["download for macos"]),

        .init("it's cut off",
              "it's cut off on mobile",
              source: "Chrome · heyyorick.com",
              facts: [pointed("Alas, poor keyboard.", "text, under “Footer”")],
              names: ["footer"]),

        // ---- The subject is IN the transcript; a prefix would be noise ----
        .init("named subject: saved list",
              "I think the saved list needs an empty state, right now it's just blank and it looks broken",
              source: "Xcode · MenuBarPanelView.swift",
              names: ["saved list", "empty state"]),

        .init("named subject: export button",
              "the export button throws when the list is empty",
              source: "Xcode · CaptureStore.swift",
              names: ["export button"]),

        .init("named subject: pricing page",
              "on the marketing site the pricing page still says beta, that needs to come down",
              source: "Slack",
              names: ["pricing page"]),

        .init("named subject with heavy scaffolding",
              "yeah so the thing is, um, I feel like the onboarding copy is just really "
              + "too long, you know, people aren't going to read all that",
              source: "Notes",
              names: ["onboarding copy"]),

        // ---- Rambling, self-correcting, conversational ----
        .init("self-correction",
              "the pill shows up at the bottom, no wait, it shows up at the bottom only "
              + "when the field is a search field, that's the case that's wrong",
              source: "Xcode · HUDContentView.swift",
              names: ["pill"]),

        .init("hedged suggestion",
              "maybe we could look at whether the settings gear is misaligned, it looks "
              + "like it's off by a pixel or two",
              source: "Xcode · MenuBarPanelView.swift",
              names: ["settings gear"]),

        .init("note to self opener",
              "note to self, we need to write down how we decide what to build next",
              source: "Notes",
              names: ["decide", "build"]),

        .init("question shaped",
              "can we make the download button more prominent on mobile?",
              source: "Chrome · heyyorick.com",
              names: ["download button"]),

        // ---- Long, meandering, multi-clause ----
        .init("long meander with a named target",
              "okay so the thing is the changelog page, I don't think anybody has touched "
              + "it since March and it's starting to look abandoned, we should either "
              + "update it or take it out of the nav",
              source: "Chrome · heyyorick.com",
              names: ["changelog"]),

        .init("symptom list, one subject",
              "onboarding is rough, the permission step doesn't explain itself and the "
              + "buttons are tiny and the whole thing feels cramped",
              source: "Notes",
              names: ["onboarding"]),

        // ---- Terse ----
        .init("terse with context",
              "wrong colour",
              source: "Figma",
              facts: [pointed("Primary button", "layer, under “Buttons”")],
              names: ["button"]),

        .init("terse, no context",
              "the appcast is stale",
              source: "Terminal",
              names: ["appcast"]),

        // ---- Deictic plus a named thing, both present ----
        .init("names one thing, points at another",
              "the way railbird does its empty states is nice, we should do that in the saved list",
              source: "Xcode · CaptureListComponents.swift",
              names: ["saved list", "empty state"]),

        // ---- An errand ----
        .init("errand",
              "remember to send the accountant the receipts from last quarter before the deadline",
              source: "Mail",
              names: ["receipts", "accountant"]),
    ]

    // MARK: - Scoring

    private struct Score {
        var named = 0
        var wellFormed = 0
        var clean = 0
        var total = 0
        var samples: [String] = []
    }

    private static func grade(_ title: String, _ testCase: Case, into score: inout Score) {
        let lowered = title.lowercased()
        score.total += 1
        // "Names it" is satisfied by ANY of the expected fragments — a title
        // needs one good noun, not all of them.
        if testCase.mustName.contains(where: { lowered.contains($0) }) { score.named += 1 }
        if !speechOpeners.contains(where: { lowered.hasPrefix($0) }) { score.wellFormed += 1 }
        if !testCase.mustNotContain.contains(where: { lowered.contains($0) }) { score.clean += 1 }
    }

    // MARK: - Run

    func testStrategiesHeadToHead() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["YORICK_EVAL"] == "1",
            "Eval is opt-in: set YORICK_EVAL=1"
        )
        try XCTSkipUnless(IssueComposer.isAvailable, "On-device model unavailable on this Mac")

        var scores: [TitleComposer.Strategy: Score] = [:]
        print("\n=== Title strategies — \(Self.cases.count) cases ===\n")

        for testCase in Self.cases {
            print("· \(testCase.name)")
            print("    said:  \"\(testCase.transcript.prefix(70))\(testCase.transcript.count > 70 ? "…" : "")\"")
            for strategy in TitleComposer.Strategy.allCases {
                let title = await Self.title(strategy, testCase.input)
                var score = scores[strategy] ?? Score()
                Self.grade(title, testCase, into: &score)
                scores[strategy] = score
                let lowered = title.lowercased()
                let namedIt = testCase.mustName.contains { lowered.contains($0) }
                print("    \(namedIt ? "✓" : "✗") \(strategy.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)) \(title)")
            }
            print("")
        }

        print("=== Results ===")
        print("strategy              names it   title-shaped   no inversion")
        for strategy in TitleComposer.Strategy.allCases {
            guard let score = scores[strategy], score.total > 0 else { continue }
            func pct(_ n: Int) -> String {
                String(format: "%3d%%", Int((Double(n) / Double(score.total) * 100).rounded()))
            }
            print("\(strategy.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0))"
                  + "\(pct(score.named)) (\(score.named)/\(score.total))"
                  + "   \(pct(score.wellFormed))"
                  + "          \(pct(score.clean))")
        }
        print("")
    }

    private static func title(
        _ strategy: TitleComposer.Strategy, _ input: IssueComposer.Input
    ) async -> String {
        switch strategy {
        case .modelAuthored:
            // The retired baseline, called directly. It has to be invoked on
            // its own now that the shipping path no longer uses it —
            // otherwise this arm silently measures the deterministic builder
            // and every strategy scores identically, which is exactly what
            // happened the first time this was re-run.
            return await IssueComposer.modelAuthoredTitle(input)
        case .deterministic:
            return TitleComposer.deterministicTitle(input)
        case .modelPicksSubject:
            return await TitleComposer.subjectPickedTitle(input)
        case .modelRanksCandidates:
            return await TitleComposer.rankedTitle(input)
        }
    }
}
