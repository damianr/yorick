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

    private static var workspace: LinearWorkspace {
        LinearWorkspace(teams: teams, projects: projects, fetchedAt: Date())
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
        /// Words the title must not lose. Empty means title isn't graded.
        let titleMustMention: [String]

        init(_ name: String, _ transcript: String, source: String,
             facts: [ContextFact] = [], expected: String?, mentions: [String] = []) {
            self.name = name
            self.transcript = transcript
            self.sourceLine = source
            self.facts = facts
            self.expected = expected
            self.titleMustMention = mentions
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
        .init("unrelated errand declines to a team",
              "remember to send the accountant the receipts from last quarter before the deadline",
              source: "Mail",
              expected: nil, mentions: ["receipt"]),

        .init("generic thought with no product signal",
              "I keep thinking we should write down how we decide what to build next, it's all in my head",
              source: "Notes",
              expected: nil),

        // --- Explicit naming should be trivially right ---
        .init("project named outright",
              "on the marketing site the pricing page still says beta, that needs to come down",
              source: "Slack",
              expected: "p-site", mentions: ["pricing"]),

        // --- Adversarial: words that pull toward the wrong project ---
        .init("decoy vocabulary",
              "the odds of someone finding this setting are basically zero, we should surface it in onboarding",
              source: "Xcode · PreferencesView.swift",
              facts: [selection("Clean up dictation before it types")],
              expected: "p-yorick"),

        .init("two products mentioned, one is the subject",
              "the way railbird does its empty states is nice, we should do that in the saved list",
              source: "Xcode · CaptureListComponents.swift",
              expected: "p-yorick"),
    ]

    // MARK: - Run

    func testRoutingAndTitles() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["YORICK_EVAL"] == "1",
            "Eval is opt-in: set YORICK_EVAL=1"
        )
        try XCTSkipUnless(IssueComposer.isAvailable, "On-device model unavailable on this Mac")

        let workspace = Self.workspace
        let options = IssueComposer.routeOptions(workspace: workspace)
        var routeHits = 0
        var titleHits = 0
        var titleGraded = 0
        var lines: [String] = []

        print("\n=== IssueComposer eval — \(Self.cases.count) cases, \(options.count) destinations ===\n")

        for testCase in Self.cases {
            let input = IssueComposer.Input(
                transcript: testCase.transcript,
                sourceLine: testCase.sourceLine,
                context: testCase.facts.isEmpty ? nil : CaptureContext(facts: testCase.facts)
            )
            let base = IssueComposer.deterministicDraft(input, teamID: "t-prod")
            let draft = await IssueComposer.compose(input, workspace: workspace, base: base)

            let routeOK = draft.projectID == testCase.expected
            if routeOK { routeHits += 1 }

            let picked = workspace.project(id: draft.projectID)?.name
                ?? "(no project · \(workspace.team(id: draft.teamID)?.name ?? "?"))"
            let wanted = Self.projects.first { $0.id == testCase.expected }?.name ?? "(no project)"

            var titleNote = ""
            if !testCase.titleMustMention.isEmpty {
                titleGraded += 1
                let lowered = draft.title.lowercased()
                let ok = testCase.titleMustMention.allSatisfy { lowered.contains($0.lowercased()) }
                if ok { titleHits += 1 }
                titleNote = ok ? "" : "  ⚠︎ title dropped \(testCase.titleMustMention)"
            }
            // A title identical to the deterministic fallback means the model
            // refused, timed out, or failed a guard — worth seeing, since a
            // silent fallback is invisible in the product by design.
            let usedFallback = draft.title == base.title
            lines.append("""
                \(routeOK ? "✓" : "✗") \(testCase.name)
                    route:  \(picked)\(routeOK ? "" : "   (wanted: \(wanted))")
                    title:  \(draft.title)\(usedFallback ? "   [deterministic fallback]" : "")\(titleNote)
                """)
            print(lines.last!)
        }

        let routePct = Int((Double(routeHits) / Double(Self.cases.count) * 100).rounded())
        let titlePct = titleGraded == 0 ? 0 : Int((Double(titleHits) / Double(titleGraded) * 100).rounded())
        print("""

            === Routing \(routeHits)/\(Self.cases.count) (\(routePct)%) · \
            Titles \(titleHits)/\(titleGraded) (\(titlePct)%) ===

            """)

        // No assertion on the score. This measures a probabilistic system to
        // inform a decision — whether the model comes off the route and it
        // becomes a plain picker. A red X here is data, not a broken build.
    }
}
