import CryptoKit
import XCTest

// MARK: - PKCE

final class PKCETests: XCTestCase {

    /// RFC 7636: the challenge is BASE64URL(SHA256(ASCII(verifier))) with
    /// padding stripped. This vector is from the RFC's own appendix, so a
    /// regression here means the flow would fail against any correct server,
    /// not just Linear's.
    func testChallengeMatchesRFCVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        let challenge = PKCEChallenge.base64URL(
            Data(SHA256.hash(data: Data(verifier.utf8)))
        )
        XCTAssertEqual(challenge, expected)
    }

    func testBase64URLHasNoPaddingOrURLUnsafeCharacters() {
        // 0xFB 0xFF encodes to "+/" in standard base64 — the two characters
        // that must be substituted.
        let encoded = PKCEChallenge.base64URL(Data([0xFB, 0xFF, 0xFE]))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
    }

    func testVerifierLengthIsWithinSpec() {
        let pkce = PKCEChallenge()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertLessThanOrEqual(pkce.verifier.count, 128)
    }

    func testEachChallengeIsUnique() {
        XCTAssertNotEqual(PKCEChallenge().verifier, PKCEChallenge().verifier)
        XCTAssertNotEqual(PKCEChallenge().state, PKCEChallenge().state)
    }
}

// MARK: - OAuth request construction

final class LinearOAuthTests: XCTestCase {

    func testAuthorizationURLCarriesPKCEAndNoSecret() {
        let pkce = PKCEChallenge()
        let url = LinearOAuth.authorizationURL(clientID: "abc123", pkce: pkce)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        XCTAssertEqual(value("client_id"), "abc123")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("code_challenge"), pkce.challenge)
        XCTAssertEqual(value("state"), pkce.state)
        XCTAssertEqual(value("scope"), "read,write")
        // Forces the workspace/consent picker. Without it, Linear can
        // return a code for the already-authorized workspace and "Switch
        // workspace" silently reconnects you to the one you were leaving.
        XCTAssertEqual(value("prompt"), "consent")
        // The verifier is the secret half; it must never appear in a URL that
        // travels through the browser.
        XCTAssertFalse(url.absoluteString.contains(pkce.verifier))
    }

    /// Not `admin`, and not the agent scopes: over-requesting would put a
    /// workspace-admin approval in front of a personal integration for
    /// capabilities it never uses.
    func testScopesAreMinimal() {
        XCTAssertFalse(LinearOAuth.scopes.contains("admin"))
        XCTAssertFalse(LinearOAuth.scopes.contains("app:"))
    }

    func testRedirectIsLoopbackOnly() {
        XCTAssertTrue(LinearOAuth.redirectURI.hasPrefix("http://127.0.0.1:"))
    }

    func testTokenBodyUsesVerifierAndOmitsClientSecret() {
        let body = LinearOAuth.tokenRequestBody(clientID: "abc", code: "the-code", verifier: "the-verifier")
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code_verifier=the-verifier"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testFormEncodingEscapesReservedCharacters() {
        let encoded = LinearOAuth.formEncode(["redirect_uri": "http://127.0.0.1:1/cb?a=b"])
        XCTAssertEqual(encoded, "redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcb%3Fa%3Db")
    }

    // MARK: Callback parsing

    func testValidCallbackYieldsCode() throws {
        let code = try LinearOAuth.authorizationCode(
            from: "/oauth/callback?code=xyz&state=s1", expectedState: "s1"
        )
        XCTAssertEqual(code, "xyz")
    }

    /// A mismatched state is a CSRF attempt or a stale browser tab. Both get
    /// refused — this is the test that matters most in this file.
    func testStateMismatchIsRejected() {
        XCTAssertThrowsError(
            try LinearOAuth.authorizationCode(from: "/cb?code=xyz&state=attacker", expectedState: "s1")
        ) { error in
            XCTAssertEqual(error as? LinearOAuthError, .stateMismatch)
        }
    }

    func testMissingStateIsRejectedEvenWithAValidCode() {
        XCTAssertThrowsError(
            try LinearOAuth.authorizationCode(from: "/cb?code=xyz", expectedState: "s1")
        ) { error in
            XCTAssertEqual(error as? LinearOAuthError, .stateMismatch)
        }
    }

    func testDeniedAuthorizationSurfacesTheReason() {
        XCTAssertThrowsError(
            try LinearOAuth.authorizationCode(from: "/cb?error=access_denied&state=s1", expectedState: "s1")
        ) { error in
            XCTAssertEqual(error as? LinearOAuthError, .denied("access_denied"))
        }
    }

    func testEmptyCodeIsMalformed() {
        XCTAssertThrowsError(
            try LinearOAuth.authorizationCode(from: "/cb?code=&state=s1", expectedState: "s1")
        ) { error in
            XCTAssertEqual(error as? LinearOAuthError, .malformedCallback)
        }
    }
}

// MARK: - The payload

final class LinearDescriptionTests: XCTestCase {

    private func fact(_ kind: String, _ value: String, detail: String? = nil) -> ContextFact {
        ContextFact(kind: kind, value: value, detail: detail, phase: "start")
    }

    /// The framing line exists because a cold receiver can't otherwise tell
    /// that the quoted block is speech rather than a message addressed to
    /// them — the exact failure mode Cleanup measured. It is deterministic
    /// and must never be model-written.
    func testDescriptionOpensWithTheFramingLineAndQuotesTheTranscript() {
        let body = LinearDescriptionBuilder.build(
            transcript: "this button is in the wrong place",
            sourceLine: "Xcode · FocusClassifier.swift",
            context: nil
        )
        XCTAssertTrue(body.hasPrefix(LinearDescriptionBuilder.framing))
        XCTAssertTrue(body.contains("> this button is in the wrong place"))
        XCTAssertTrue(body.contains("- Spoken in Xcode · FocusClassifier.swift"))
    }

    func testEveryTranscriptLineIsQuoted() {
        let body = LinearDescriptionBuilder.build(
            transcript: "first line\nsecond line",
            sourceLine: "Notes",
            context: nil
        )
        XCTAssertTrue(body.contains("> first line"))
        XCTAssertTrue(body.contains("> second line"))
    }

    func testContextFactsRenderWithProvenance() {
        let context = CaptureContext(facts: [
            fact("selection", "the quarterly figures"),
            fact("pageURL", "https://example.com/reports"),
        ])
        let lines = LinearDescriptionBuilder.contextLines(context)
        XCTAssertTrue(lines.contains("- Selected text: \"the quarterly figures\""))
        XCTAssertTrue(lines.contains("- Page: https://example.com/reports"))
    }

    /// Chrome answers AXDocument with the page URL; printing both is noise
    /// for the receiver.
    func testDocumentDuplicatingThePageURLIsSuppressed() {
        let context = CaptureContext(facts: [
            fact("pageURL", "https://example.com/x"),
            fact("document", "https://example.com/x"),
        ])
        let lines = LinearDescriptionBuilder.contextLines(context)
        XCTAssertEqual(lines.filter { $0.contains("https://example.com/x") }.count, 1)
    }

    /// Pointing is a gesture, not a moment: a sweep must arrive in order, not
    /// collapsed to one frozen word.
    func testPointerSweepRendersInOrder() {
        let context = CaptureContext(facts: [
            ContextFact(kind: "pointedElement", value: "Row one", detail: "row", phase: "timeline"),
            ContextFact(kind: "pointedElement", value: "Row two", detail: "row", phase: "timeline"),
        ])
        let lines = LinearDescriptionBuilder.contextLines(context)
        XCTAssertTrue(lines.contains("- Pointed at while speaking, in order:"))
        let one = lines.firstIndex { $0.contains("Row one") }
        let two = lines.firstIndex { $0.contains("Row two") }
        XCTAssertNotNil(one)
        XCTAssertNotNil(two)
        XCTAssertLessThan(one!, two!)
    }

    func testSinglePointedElementReadsAsSingular() {
        let context = CaptureContext(facts: [
            ContextFact(kind: "pointedElement", value: "Save", detail: "button", phase: "timeline")
        ])
        XCTAssertEqual(LinearDescriptionBuilder.contextLines(context), ["- Pointed at: Save (button)"])
    }

    /// Chrome appends the profile name to every window title, so the source
    /// line was publishing "- Google Chrome - damian" into every ticket while
    /// also duplicating the Page line right under it.
    func testSpokenInLineIsSuppressedWhenAPageURLIsPresent() {
        let body = LinearDescriptionBuilder.build(
            transcript: "these buttons could be more bone like",
            sourceLine: "Yorick: you talk, it types. - Google Chrome - damian",
            windowTitle: "Yorick: you talk, it types. - Google Chrome - damian",
            context: CaptureContext(facts: [fact("pageURL", "https://heyyorick.com/")])
        )
        XCTAssertFalse(body.contains("Spoken in"))
        XCTAssertFalse(body.contains("damian"))
        XCTAssertTrue(body.contains("- Page: https://heyyorick.com/"))
    }

    // MARK: Page title — a URL is a handle, a title is a name

    /// The leak that started this: browsers append their own name and the
    /// profile, and truncating at the browser name takes both.
    func testBrowserFurnitureAndProfileAreStripped() {
        XCTAssertEqual(
            LinearDescriptionBuilder.sanitizedWindowTitle(
                "InfuseFlow | Calendar - Google Chrome - damian"),
            "InfuseFlow | Calendar"
        )
        // A title containing its own dashes must survive intact.
        XCTAssertEqual(
            LinearDescriptionBuilder.sanitizedWindowTitle("Q3 - planning - notes"),
            "Q3 - planning - notes"
        )
    }

    /// localhost, an IP, or an opaque file id say nothing. The title is then
    /// the only identity in the entire payload, so it has to survive.
    func testTitleSurvivesWhenTheURLIsUninformative() {
        for url in ["http://localhost:3000/settings",
                    "http://127.0.0.1:8080/",
                    "https://figma.com/file/aB3xQ/Untitled",
                    "https://drive.google.com/file/d/1a2b3c/view"] {
            XCTAssertFalse(
                LinearDescriptionBuilder.titleIsRedundant("InfuseFlow | Calendar", withURL: url),
                "title should survive against \(url)"
            )
        }
    }

    /// When the title merely restates the host, one of them is noise.
    func testTitleIsDroppedWhenItRestatesTheHost() {
        XCTAssertTrue(LinearDescriptionBuilder.titleIsRedundant("Yorick", withURL: "https://heyyorick.com/"))
        XCTAssertTrue(LinearDescriptionBuilder.titleIsRedundant("GitHub", withURL: "https://github.com/damianr/yorick"))
    }

    /// A path segment matching the title is normal and must not count.
    func testPathMatchesDoNotMakeATitleRedundant() {
        XCTAssertFalse(
            LinearDescriptionBuilder.titleIsRedundant("Yorick", withURL: "https://github.com/damianr/yorick")
        )
    }

    func testPageTitleLineAppearsForALocalDevURL() {
        let body = LinearDescriptionBuilder.build(
            transcript: "the calendar column headers are misaligned",
            sourceLine: "InfuseFlow | Calendar - Google Chrome - damian",
            windowTitle: "InfuseFlow | Calendar - Google Chrome - damian",
            context: CaptureContext(facts: [fact("pageURL", "http://localhost:3000/calendar")])
        )
        XCTAssertTrue(body.contains("- Page: http://localhost:3000/calendar"))
        XCTAssertTrue(body.contains("- Page title: InfuseFlow | Calendar"))
        XCTAssertFalse(body.contains("damian"))
    }

    /// Without a URL there's nothing else carrying identity, so it stays.
    func testSpokenInLineSurvivesWithoutAPageURL() {
        let body = LinearDescriptionBuilder.build(
            transcript: "the export throws on an empty list",
            sourceLine: "Xcode · CaptureStore.swift",
            windowTitle: "CaptureStore.swift",
            context: nil
        )
        XCTAssertTrue(body.contains("- Spoken in Xcode · CaptureStore.swift"))
    }

    /// The sweep catches the document on its way to the referent. A pointed
    /// fact that just restates the page title reads as evidence and dilutes
    /// the fact that is.
    func testPointedElementEchoingTheTitleIsDropped() {
        let title = "Yorick: you talk, it types. Free local dictation for macOS. - Google Chrome"
        let context = CaptureContext(facts: [
            ContextFact(kind: "pointedElement", value: "Yorick: you talk, it types. Free local dictation for macOS.",
                        detail: "HTML content", phase: "timeline"),
            ContextFact(kind: "pointedElement", value: "Download for macOS", detail: "link", phase: "timeline"),
        ])
        let lines = LinearDescriptionBuilder.contextLines(context, windowTitle: title)
        XCTAssertEqual(lines, ["- Pointed at: Download for macOS (link)"])
    }

    /// A short label must not vanish just because its word appears in the
    /// window title — that would delete the referent to remove noise.
    func testShortPointedLabelSurvivesEvenIfTheTitleContainsIt() {
        let context = CaptureContext(facts: [
            ContextFact(kind: "pointedElement", value: "Save", detail: "button", phase: "timeline")
        ])
        let lines = LinearDescriptionBuilder.contextLines(context, windowTitle: "Save your work — Notes")
        XCTAssertEqual(lines, ["- Pointed at: Save (button)"])
    }

    func testEchoDetectionIgnoresAnEmptyWindowTitle() {
        XCTAssertFalse(LinearDescriptionBuilder.echoesDocumentTitle("some long pointed value", windowTitle: ""))
    }

    /// The placeholder has to be findable, because the send path swaps it
    /// for rendered markdown — a shape change here would silently append
    /// images instead of replacing the line the preview showed.
    func testScreenshotCountLineIsPresentAndMatchesThePlaceholderShape() {
        let body = LinearDescriptionBuilder.build(
            transcript: "the spacing here is off",
            sourceLine: "Figma",
            context: nil,
            screenshotCount: 2
        )
        XCTAssertTrue(body.contains("- 2 screenshots attached"))
        let placeholder = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("- ") && $0.hasSuffix("attached") }
        XCTAssertNotNil(placeholder)
    }

    func testSingleScreenshotReadsSingular() {
        let body = LinearDescriptionBuilder.build(
            transcript: "the spacing here is off", sourceLine: "Figma",
            context: nil, screenshotCount: 1
        )
        XCTAssertTrue(body.contains("- 1 screenshot attached"))
    }

    /// "attached" is true of an issue that carries the upload and false of a
    /// clipboard paste, where the image rides as a separate representation
    /// that plain-text targets drop.
    func testTheScreenshotLineTellsTheTruthForItsDestination() {
        let tracker = LinearDescriptionBuilder.build(
            transcript: "the spacing here is off", sourceLine: "Figma",
            context: nil, screenshotCount: 1, destination: .tracker
        )
        XCTAssertTrue(tracker.contains("- 1 screenshot attached"))

        let clipboard = LinearDescriptionBuilder.build(
            transcript: "the spacing here is off", sourceLine: "Figma",
            context: nil, screenshotCount: 1, destination: .clipboard
        )
        XCTAssertFalse(clipboard.contains("attached"))
        XCTAssertTrue(clipboard.contains("also on the clipboard"))
    }

    func testCopiedTicketLeadsWithTheTitle() {
        let ticket = TicketClipboard.text(
            title: "Optional cleanup — de-emphasize this section",
            transcript: "I want to de-emphasize this section here",
            sourceLine: "Chrome · heyyorick.com", windowTitle: "",
            context: nil, screenshotCount: 0
        )
        XCTAssertTrue(ticket.hasPrefix("# Optional cleanup — de-emphasize this section\n\n"))
        XCTAssertTrue(ticket.contains(LinearDescriptionBuilder.framing))
        XCTAssertTrue(ticket.contains("> I want to de-emphasize this section here"))
    }

    func testNoScreenshotsAddsNoLine() {
        let body = LinearDescriptionBuilder.build(
            transcript: "the spacing here is off", sourceLine: "Figma", context: nil
        )
        XCTAssertFalse(body.contains("attached"))
    }

    func testNoContextProducesNoContextLines() {
        XCTAssertTrue(LinearDescriptionBuilder.contextLines(nil).isEmpty)
        XCTAssertTrue(LinearDescriptionBuilder.contextLines(CaptureContext(facts: [])).isEmpty)
    }
}

// MARK: - Fallback title

final class LinearFallbackTitleTests: XCTestCase {

    /// This is what a failed compose produces, so it has to be good enough to
    /// ship on its own — that's what lets the model fail silently.
    func testFirstSentenceBecomesTheTitle() {
        let title = LinearDescriptionBuilder.fallbackTitle(
            transcript: "The export button is broken. It throws when the list is empty."
        )
        XCTAssertEqual(title, "The export button is broken")
    }

    func testShortLeadingFragmentFallsBackToTheWholeUtterance() {
        // "Hey." is too short to be the title; the whole line is better.
        let title = LinearDescriptionBuilder.fallbackTitle(transcript: "Hey. The sidebar is misaligned.")
        XCTAssertTrue(title.contains("sidebar"))
    }

    func testLongTitlesTruncateAtAWordBoundary() {
        let long = String(repeating: "alpha ", count: 40)
        let title = LinearDescriptionBuilder.fallbackTitle(transcript: long)
        XCTAssertLessThanOrEqual(title.count, 81)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertFalse(title.contains("alph…"))
    }

    func testEmptyTranscriptStillProducesATitle() {
        XCTAssertEqual(LinearDescriptionBuilder.fallbackTitle(transcript: "   "), "Voice capture")
    }
}

// MARK: - Composer guards

final class IssueComposerGuardTests: XCTestCase {

    private let transcript = "the export button throws when the list is empty"

    func testPlainCompressionIsAccepted() {
        XCTAssertEqual(
            IssueComposer.validatedTitle("Export button throws when the list is empty", transcript: transcript),
            "Export button throws when the list is empty"
        )
    }

    /// The readback lesson, applied: a pointed-at headline once became a
    /// "product name" and the line asserted something nobody said. An
    /// invented proper noun on a ticket somebody else will act on is a
    /// fabrication, not a compression.
    func testInventedProperNounIsRejected() {
        XCTAssertNil(
            IssueComposer.validatedTitle("Acme Reporter export throws on empty list", transcript: transcript)
        )
    }

    func testProperNounActuallySpokenIsKept() {
        let spoken = "the Linear export throws when the list is empty"
        XCTAssertNotNil(IssueComposer.validatedTitle("Linear export throws on empty list", transcript: spoken))
    }

    func testMultiLineOutputIsRejected() {
        XCTAssertNil(IssueComposer.validatedTitle("export button\nthrows on empty", transcript: transcript))
    }

    func testEmptyTitleIsRejected() {
        XCTAssertNil(IssueComposer.validatedTitle("   ", transcript: transcript))
    }

    /// A "title" longer than the utterance means the model wrote a body, or
    /// worse, answered the transcript.
    func testTitleLongerThanTheUtteranceIsRejected() {
        let short = "fix the header"
        let bloated = "The header component should be refactored to use the new layout system across all pages"
        XCTAssertNil(IssueComposer.validatedTitle(bloated, transcript: short))
    }

    func testWordCountGateMatchesTheMinimum() {
        XCTAssertLessThan(IssueComposer.wordCount("empty fuel"), IssueComposer.minimumWords)
        XCTAssertGreaterThanOrEqual(IssueComposer.wordCount(transcript), IssueComposer.minimumWords)
    }
}

// MARK: - Routing menu

final class IssueComposerRouteTests: XCTestCase {

    private let engineering = LinearTeam(id: "t1", name: "Engineering", key: "ENG")
    private let design = LinearTeam(id: "t2", name: "Design", key: "DES")

    private var workspaces: LinearWorkspaces {
        LinearWorkspaces(all: [workspace])
    }

    private var workspace: LinearWorkspace {
        LinearWorkspace(
            organizationID: "org-1", organizationName: "Acme",
            teams: [engineering, design],
            projects: [
                LinearProject(id: "p1", name: "Onboarding", summary: "First-run flow", teamIDs: ["t1"]),
                LinearProject(id: "p2", name: "Design System", summary: nil, teamIDs: ["t2"]),
            ],
            fetchedAt: Date()
        )
    }

    /// "No specific project" must always be reachable, so a model with no
    /// good match can decline to guess instead of picking a wrong project.
    func testEveryTeamAppearsWithoutAProject() {
        let options = IssueComposer.routeOptions(workspaces: workspaces)
        XCTAssertTrue(options.contains { $0.teamID == "t1" && $0.projectID == nil })
        XCTAssertTrue(options.contains { $0.teamID == "t2" && $0.projectID == nil })
    }

    func testProjectsAppearUnderTheirOwnTeam() {
        let options = IssueComposer.routeOptions(workspaces: workspaces)
        let onboarding = options.first { $0.projectID == "p1" }
        XCTAssertEqual(onboarding?.teamID, "t1")
        XCTAssertTrue(onboarding?.label.contains("Engineering › Onboarding") == true)
        // The project description is the strongest signal the model gets.
        XCTAssertTrue(onboarding?.label.contains("First-run flow") == true)
    }

    /// A menu longer than this stops being a choice and becomes a search
    /// problem, which is not what a small model is good at.
    func testMenuIsCapped() {
        let manyTeams = (0..<50).map { LinearTeam(id: "t\($0)", name: "Team \($0)", key: "T\($0)") }
        let big = LinearWorkspace(organizationID: "o", organizationName: "Big", teams: manyTeams, projects: [], fetchedAt: Date())
        XCTAssertLessThanOrEqual(IssueComposer.routeOptions(workspaces: LinearWorkspaces(all: [big])).count, 30)
    }

    func testPromptCarriesTheNoteContextAndNumberedMenu() {
        let input = IssueComposer.Input(
            transcript: "the first-run flow drops you on a blank screen",
            sourceLine: "Xcode · OnboardingView.swift",
            context: CaptureContext(facts: [
                ContextFact(kind: "selection", value: "welcome step", detail: "AXTextArea", phase: "start")
            ])
        )
        let prompt = IssueComposer.routePrompt(input, options: IssueComposer.routeOptions(workspaces: workspaces))
        XCTAssertTrue(prompt.contains("the first-run flow drops you on a blank screen"))
        XCTAssertTrue(prompt.contains("- Spoken in Xcode · OnboardingView.swift"))
        XCTAssertTrue(prompt.contains("- Selected text: \"welcome step\""))
        XCTAssertTrue(prompt.contains("1. "))
    }

    func testDeterministicDraftUsesTheGivenTeamAndNoProject() {
        let input = IssueComposer.Input(transcript: "something is broken here", sourceLine: "Safari", context: nil)
        let draft = IssueComposer.deterministicDraft(input, teamID: "t1")
        XCTAssertEqual(draft.teamID, "t1")
        XCTAssertNil(draft.projectID)
        XCTAssertFalse(draft.title.isEmpty)
        XCTAssertTrue(draft.description.contains("> something is broken here"))
    }
}

// MARK: - Workspace mirror

final class LinearWorkspaceTests: XCTestCase {

    func testProjectsFilterByTeam() {
        let workspace = LinearWorkspace(
            teams: [LinearTeam(id: "t1", name: "Eng", key: "ENG")],
            projects: [
                LinearProject(id: "p1", name: "A", summary: nil, teamIDs: ["t1"]),
                LinearProject(id: "p2", name: "B", summary: nil, teamIDs: ["t2"]),
            ],
            fetchedAt: Date()
        )
        XCTAssertEqual(workspace.projects(forTeam: "t1").map(\.id), ["p1"])
    }

    /// A stale mirror costs one correction; a mirror that never expires
    /// routes this quarter's captures into last quarter's projects.
    func testStalenessIsADayOld() {
        let fresh = LinearWorkspace(teams: [], projects: [], fetchedAt: Date())
        let old = LinearWorkspace(teams: [], projects: [], fetchedAt: Date().addingTimeInterval(-90_000))
        XCTAssertFalse(fresh.isStale)
        XCTAssertTrue(old.isStale)
    }
}

// MARK: - Token expiry

final class LinearTokenTests: XCTestCase {

    func testTokenWithoutAStatedLifetimeNeverExpires() {
        let tokens = LinearKeychain.Tokens(accessToken: "a", refreshToken: nil, expiresAt: nil)
        XCTAssertFalse(tokens.isExpired)
    }

    /// A minute of slack, so a token that would expire mid-flight refreshes
    /// before the request rather than failing it.
    func testTokenExpiringWithinTheSlackWindowCountsAsExpired() {
        let soon = LinearKeychain.Tokens(
            accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(30)
        )
        XCTAssertTrue(soon.isExpired)

        let later = LinearKeychain.Tokens(
            accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(600)
        )
        XCTAssertFalse(later.isExpired)
    }
}
