import XCTest

/// An EVAL, not a unit test: it calls the real on-device model and reports
/// how often it routes and titles correctly. Opt-in, because it needs Apple
/// Intelligence, takes tens of seconds, and is not deterministic — three
/// things a test suite should never be.
///
///   YORICK_EVAL=1 xcodebuild -project Yorick.xcodeproj -scheme Yorick \
///     -derivedDataPath build/DerivedData test \
///     -only-testing:YorickTests/IssueComposerEval
///
/// This exists because the routing question is the real risk in the Linear
/// exit and it is fully separable from Linear: the composer takes a
/// transcript and a menu, and the menu can be a fixture. The method is the
/// one Cleanup used — replay realistic utterances, measure, tune the prompt
/// against what actually happens rather than what should.
final class IssueComposerEval: XCTestCase {

    // MARK: - The answer key

    private static let teams = [
        LinearTeam(id: "t-prod", name: "Products", key: "PRD"),
        LinearTeam(id: "t-ops", name: "Operations", key: "OPS"),
    ]

    /// Shaped like a real personal workspace: several sibling products whose
    /// names do NOT appear in most utterances, so routing has to work off
    /// subject matter and context rather than string matching. That is the
    /// case that matters — if it only works when you say the project name,
    /// the feature is a search box.
    private static let projects = [
        LinearProject(id: "p-yorick", name: "Yorick",
                      summary: "Local-only macOS dictation. Hotkey, pill, transcription, the saved list.",
                      teamIDs: ["t-prod"]),
        LinearProject(id: "p-infuse", name: "InfuseFlow",
                      summary: "Infusion scheduling and patient records for clinics.",
                      teamIDs: ["t-prod"]),
        LinearProject(id: "p-railbird", name: "Railbird",
                      summary: "Sports betting analytics and odds tracking.",
                      teamIDs: ["t-prod"]),
        LinearProject(id: "p-safeyum", name: "SafeYum",
                      summary: "Food allergy scanning for parents of kids with allergies.",
                      teamIDs: ["t-prod"]),
        LinearProject(id: "p-site", name: "Marketing site",
                      summary: "heyyorick.com — hero, copy, pricing page, SEO.",
                      teamIDs: ["t-prod"]),
        LinearProject(id: "p-admin", name: "Admin",
                      summary: "Invoicing, contracts, taxes, vendor accounts.",
                      teamIDs: ["t-ops"]),
    ]

    private static var workspaces: LinearWorkspaces {
        LinearWorkspaces(all: [LinearWorkspace(
            organizationID: "org", organizationName: "Acme",
            teams: teams, projects: projects, fetchedAt: Date()
        )])
    }

    // MARK: - Cases

    private struct Case {
        let name: String
        let transcript: String
        let sourceLine: String
        let facts: [ContextFact]
        /// Project id the route should land on. Nil means "no project is the
        /// right answer" — the model should decline to guess.
        let expected: String?
        /// Other answers that are defensible. A route question with two
        /// reasonable answers should not be scored as a failure; pretending
        /// otherwise makes the eval measure the fixture, not the model.
        let alsoAccept: [String?]
        /// Words the title must not lose. Empty means title isn't graded.
        let titleMustMention: [String]
        /// Grade the title's SHAPE as well as its content. A title that opens
        /// with "I", "we", or a bare demonstrative is a sentence lifted from
        /// speech — the exact field failure this eval exists to catch.
        let titleMustBeWellFormed: Bool

        init(_ name: String, _ transcript: String, source: String,
             facts: [ContextFact] = [], expected: String?,
             alsoAccept: [String?] = [], mentions: [String] = [],
             wellFormed: Bool = false) {
            self.name = name
            self.transcript = transcript
            self.sourceLine = source
            self.facts = facts
            self.expected = expected
            self.alsoAccept = alsoAccept
            self.titleMustMention = mentions
            self.titleMustBeWellFormed = wellFormed
        }

        /// Openers that mean the model transcribed rather than titled.
        static let banned = ["i ", "i'", "we ", "we'", "this ", "that ", "maybe ", "so ", "uh "]

        func accepts(_ projectID: String?) -> Bool {
            projectID == expected || alsoAccept.contains(projectID)
        }
    }

    private static func pointed(_ value: String, _ detail: String = "row") -> ContextFact {
        ContextFact(kind: "pointedElement", value: value, detail: detail, phase: "timeline")
    }

    private static func selection(_ value: String) -> ContextFact {
        ContextFact(kind: "selection", value: value, detail: "AXTextArea", phase: "start")
    }

    private static func page(_ url: String) -> ContextFact {
        ContextFact(kind: "pageURL", value: url, detail: nil, phase: "start")
    }

    private static let cases: [Case] = [
        // --- Routing on subject matter alone, project name never spoken ---
        .init("dictation bug, named by symptom",
              "the pill is showing up in the bottom center even when I'm in a text field, it should be anchored",
              source: "Xcode · HUDContentView.swift",
              expected: "p-yorick", mentions: ["pill"]),

        .init("clinic feature, no product name",
              "we need a way for the nurse to see which infusion chairs are free before she books someone in",
              source: "Safari · Scheduling",
              expected: "p-infuse", mentions: ["chair"]),

        .init("allergy scanning, no product name",
              "scanning a label with no barcode should still work, a lot of the bulk stuff at the store has no barcode",
              source: "Notes",
              expected: "p-safeyum", mentions: ["barcode"]),

        // --- Routing that requires CONTEXT, not the words ---
        .init("vague words, context carries it",
              "this whole section reads badly, it's way too long and nobody's going to get past the first line",
              source: "Chrome · heyyorick.com",
              facts: [page("https://heyyorick.com"), pointed("Privacy you can check · nothing leaves your Mac")],
              expected: "p-site"),

        .init("pure demonstrative, pointed evidence only",
              "this number is wrong",
              source: "Chrome · Odds dashboard",
              facts: [page("https://railbird.app/odds"),
                      pointed("Lakers · -110 · implied 52.4%", "row")],
              expected: "p-railbird"),

        .init("selection carries the referent",
              "we should reword this, it sounds like we're apologizing",
              source: "Xcode · OnboardingView.swift",
              facts: [selection("Yorick needs a couple of permissions before it can help")],
              expected: "p-yorick"),

        // --- The decline case: nothing matches, must not guess a project ---
        // NOTE: this one's answer key was wrong in the first eval. "Send the
        // accountant the receipts" IS what the Admin project is for
        // ("invoicing, contracts, taxes"), so the model routing it there was
        // correct and the eval was marking it a miss. Both answers accepted.
        .init("errand belonging to ops",
              "remember to send the accountant the receipts from last quarter before the deadline",
              source: "Mail",
              expected: nil, alsoAccept: ["p-admin"], mentions: ["receipt"]),

        .init("generic thought with no product signal",
              "I keep thinking we should write down how we decide what to build next, it's all in my head",
              source: "Notes",
              expected: nil),

        // --- Explicit naming should be trivially right ---
        .init("project named outright",
              "on the marketing site the pricing page still says beta, that needs to come down",
              source: "Slack",
              expected: "p-site", mentions: ["pricing"]),

        // --- FIELD CASES. Real captures that produced bad titles. ---
        .init("field miss: de-emphasize a section",
              "I want to de-emphasize this section here. Uh, I just don't know that "
              + "we really need it. Maybe we can come up with something else that goes there.",
              source: "Chrome · heyyorick.com",
              facts: [page("https://heyyorick.com/"),
                      pointed("Ums and false starts come out before the text is typed.",
                              "text, under “Optional cleanup”"),
                      pointed("Optional cleanup", "text")],
              expected: "p-site", mentions: ["cleanup"], wellFormed: true),

        .init("rambling ask with a named target",
              "yeah so the thing is the download button, I feel like it just gets lost "
              + "down there, we should probably move it up or make it louder somehow",
              source: "Chrome · heyyorick.com",
              facts: [page("https://heyyorick.com/"), pointed("Download for macOS", "link")],
              expected: "p-site", mentions: ["download"], wellFormed: true),

        .init("first-person opener with a clear subject",
              "I think the saved list needs an empty state, right now it's just blank "
              + "and it looks broken",
              source: "Xcode · MenuBarPanelView.swift",
              expected: "p-yorick", mentions: ["empty state"], wellFormed: true),

        // --- Adversarial: words that pull toward the wrong project ---
        .init("decoy vocabulary",
              "the odds of someone finding this setting are basically zero, we should surface it in onboarding",
              source: "Xcode · PreferencesView.swift",
              facts: [selection("Clean up dictation before it types")],
              expected: "p-yorick"),

        // --- DEIXIS. The point of the context layer: a demonstrative that
        // resolves only against what the pointer was on. Titles are graded
        // here on whether the REFERENT survives, which is the thing the
        // widened allowlist exists to permit.
        .init("this section, resolved by heading",
              "this whole section is way too long, nobody's getting past the first line",
              source: "Chrome · heyyorick.com",
              facts: [page("https://heyyorick.com/"),
                      pointed("Nothing you say is lost, and nothing leaves your Mac",
                              "paragraph, under “Nothing's lost”")],
              expected: "p-site", mentions: ["nothing's lost"]),

        .init("this one, resolved by row",
              "this one's been sitting there for weeks, we should just close it",
              source: "Chrome · Odds dashboard",
              facts: [page("https://railbird.app/odds"),
                      pointed("Warriors · -145 · stale since Jun 2", "row")],
              expected: "p-railbird", mentions: ["warriors"]),

        .init("these, resolved by selection",
              "these need to be consistent, half of them say one thing and half the other",
              source: "Xcode · PreferencesView.swift",
              facts: [selection("Clean up dictation before it types")],
              expected: "p-yorick", mentions: ["clean up dictation"]),

        .init("two products mentioned, one is the subject",
              "the way railbird does its empty states is nice, we should do that in the saved list",
              source: "Xcode · CaptureListComponents.swift",
              expected: "p-yorick"),
    ]

    // MARK: - Run

    /// Set per run so both routing strategies are measured over the same
    /// corpus rather than compared across separate runs, where the model's
    /// own variance would swamp the difference.
    nonisolated(unsafe) static var strategyUnderTest: IssueComposer.RoutingStrategy = .flat

    func testRoutingFlat() async throws {
        Self.strategyUnderTest = .flat
        try await runRoutingEval(label: "FLAT")
    }

    func testRoutingTwoStage() async throws {
        Self.strategyUnderTest = .twoStage
        try await runRoutingEval(label: "TWO-STAGE")
    }

    private func runRoutingEval(label: String) async throws {
        print("\n########## \(label) ##########")
        try await testRoutingAndTitles()
    }

    func testRoutingAndTitles() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["YORICK_EVAL"] == "1",
            "Eval is opt-in: set YORICK_EVAL=1"
        )
        try XCTSkipUnless(IssueComposer.isAvailable, "On-device model unavailable on this Mac")

        let workspaces = Self.workspaces
        let options = IssueComposer.routeOptions(workspaces: workspaces)
        // Three passes per case. Measured the hard way: three single-pass
        // runs of this eval scored 7/11, 5/11, 7/11, and WHICH cases passed
        // shuffled each time. A single pass cannot tell a prompt change from
        // sampling noise, which is exactly the mistake that made the
        // confidence experiment look conclusive when it wasn't.
        let passes = 3
        var routeHits = 0, routeTotal = 0
        var titleHits = 0, titleTotal = 0

        print("\n=== IssueComposer eval — \(Self.cases.count) cases × \(passes) passes, \(options.count) destinations ===\n")

        for testCase in Self.cases {
            let input = IssueComposer.Input(
                transcript: testCase.transcript,
                sourceLine: testCase.sourceLine,
                context: testCase.facts.isEmpty ? nil : CaptureContext(facts: testCase.facts)
            )
            let base = IssueComposer.deterministicDraft(input, teamID: "t-prod")

            var caseHits = 0
            var picks: [String] = []
            var titleNote = ""

            for _ in 0..<passes {
                let route = await IssueComposer.proposeRoute(
                    input, workspaces: workspaces, fallbackTeamID: "t-prod",
                    strategy: Self.strategyUnderTest
                )
                var draft = base
                draft.teamID = route.teamID
                draft.projectID = route.projectID
                draft.title = TitleComposer.deterministicTitle(input)
                let result = (draft: draft, route: Optional(route), usedModelTitle: false)
                routeTotal += 1
                if testCase.accepts(draft.projectID) { caseHits += 1; routeHits += 1 }

                let name = workspaces.project(id: draft.projectID)?.name
                    ?? "team:\(workspaces.team(id: draft.teamID)?.team.name ?? "?")"
                let conf = result.route?.confidence.map { "\($0)" } ?? "-"
                picks.append("\(name)(c\(conf))")

                if !testCase.titleMustMention.isEmpty || testCase.titleMustBeWellFormed {
                    titleTotal += 1
                    let lowered = draft.title.lowercased()
                    let mentions = testCase.titleMustMention
                        .allSatisfy { lowered.contains($0.lowercased()) }
                    let wellFormed = !testCase.titleMustBeWellFormed
                        || !Case.banned.contains { lowered.hasPrefix($0) }
                    if mentions, wellFormed {
                        titleHits += 1
                    } else if !wellFormed {
                        titleNote = "  ⚠︎ reads as speech: \"\(draft.title)\""
                    } else {
                        titleNote = "  ⚠︎ dropped \(testCase.titleMustMention): \"\(draft.title)\""
                    }
                }
            }

            let wanted = Self.projects.first { $0.id == testCase.expected }?.name ?? "(no project)"
            let mark = caseHits == passes ? "✓" : (caseHits == 0 ? "✗" : "~")
            print("""
                \(mark) \(caseHits)/\(passes)  \(testCase.name)
                    picks:  \(picks.joined(separator: ", "))\(caseHits == passes ? "" : "   wanted: \(wanted)")\(titleNote)
                """)
        }

        let routePct = Int((Double(routeHits) / Double(routeTotal) * 100).rounded())
        let titlePct = titleTotal == 0 ? 0 : Int((Double(titleHits) / Double(titleTotal) * 100).rounded())
        print("""

            === Routing \(routeHits)/\(routeTotal) (\(routePct)%) · \
            Titles \(titleHits)/\(titleTotal) (\(titlePct)%) ===
            ✓ = right on every pass · ~ = unstable · ✗ = wrong on every pass

            """)

        // No assertion on the score. This measures a probabilistic system to
        // inform a decision — whether the model comes off the route and it
        // becomes a plain picker. A red X here is data, not a broken build.
    }
}
