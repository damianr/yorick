import XCTest

/// Deterministic project matching, pinned. The two bugs here were found by
/// measurement, not by reading, and both had the same shape: a match that
/// looked right in isolation and was wrong in company.
final class ProjectMatcherTests: XCTestCase {

    private let single = LinearWorkspace(
        organizationID: "org-1", organizationName: "Acme",
        teams: [LinearTeam(id: "t-prod", name: "Products", key: "P")],
        projects: [
            LinearProject(id: "p-yorick", name: "Yorick",
                          summary: "Local-only macOS dictation. Hotkey, pill, transcription.",
                          teamIDs: ["t-prod"]),
            LinearProject(id: "p-site", name: "Marketing site",
                          summary: "heyyorick.com — hero, copy, pricing page, SEO.",
                          teamIDs: ["t-prod"]),
            LinearProject(id: "p-railbird", name: "Railbird",
                          summary: "Sports betting analytics.", teamIDs: ["t-prod"]),
        ],
        fetchedAt: Date()
    )
    private var workspaces: LinearWorkspaces { LinearWorkspaces(all: [single]) }

    private func input(
        _ transcript: String, source: String = "Notes", page: String? = nil
    ) -> IssueComposer.Input {
        let facts = page.map {
            [ContextFact(kind: "pageURL", value: $0, detail: nil, phase: "start")]
        } ?? []
        return IssueComposer.Input(
            transcript: transcript, sourceLine: source, windowTitle: "",
            context: facts.isEmpty ? nil : CaptureContext(facts: facts)
        )
    }

    /// The failure this whole file exists for: every marketing-site capture
    /// missed on every eval run, while the answer sat in plain sight — the
    /// project's summary names the host the capture was on.
    func testHostInAProjectSummaryDecidesOutright() {
        let hits = ProjectMatcher.matches(
            input("this whole section reads badly",
                  source: "Chrome · heyyorick.com", page: "https://heyyorick.com"),
            workspaces: workspaces
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.projectID, "p-site")
        XCTAssertTrue(ProjectMatcher.isDecisive(hits[0]))
    }

    /// Bug one: "Yorick" substring-matched inside "heyyorick.com", so the
    /// product project matched on place and the answer stopped being
    /// decidable. Names have to match on word boundaries.
    func testAProjectNameDoesNotMatchInsideAnotherWord() {
        let hits = ProjectMatcher.matches(
            input("something", source: "Chrome · heyyorick.com"),
            workspaces: workspaces
        )
        XCTAssertFalse(hits.contains { $0.projectID == "p-yorick" })
    }

    /// Bug two: without precedence, one incidental weak match was enough to
    /// turn a decided answer back into a guess.
    func testAHostMatchOutranksWeakerSignals() {
        let hits = ProjectMatcher.matches(
            input("the railbird thing", source: "Chrome · heyyorick.com",
                  page: "https://heyyorick.com"),
            workspaces: workspaces
        )
        XCTAssertEqual(hits.map(\.projectID), ["p-site"])
    }

    func testWwwIsIgnoredWhenMatchingHosts() {
        let hits = ProjectMatcher.matches(
            input("x", page: "https://www.heyyorick.com/pricing"), workspaces: workspaces
        )
        XCTAssertEqual(hits.first?.projectID, "p-site")
    }

    /// A spoken project name is a candidate, but never decisive — "the way
    /// Railbird does its empty states is nice, we should do that in the saved
    /// list" is a note about the saved list.
    func testASpokenNameIsACandidateButNotDecisive() {
        let hits = ProjectMatcher.matches(input("the railbird numbers look off"), workspaces: workspaces)
        XCTAssertEqual(hits.first?.projectID, "p-railbird")
        XCTAssertFalse(ProjectMatcher.isDecisive(hits[0]))
    }

    /// No evidence means no opinion: the model decides, from everything.
    func testNoSignalYieldsNoMatches() {
        XCTAssertTrue(ProjectMatcher.matches(
            input("we should write down how we decide what to build"), workspaces: workspaces
        ).isEmpty)
    }

    func testAnUnrelatedHostMatchesNothing() {
        XCTAssertTrue(ProjectMatcher.matches(
            input("x", page: "https://news.ycombinator.com"), workspaces: workspaces
        ).isEmpty)
    }
}
