import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a saved capture into a proposed Linear issue, entirely on-device.
///
/// Why a model is allowed here at all, when the enrichment era's classifier
/// was deleted for cause: the task changed shape. v1 asked the model to
/// INVENT a taxonomy — kinds, tags, project names — with no right answer and
/// no way to check the output. This asks it to PICK from the workspace's real
/// teams and projects, a handful of options with a right answer the user can
/// see and correct before anything is sent. Constrained choice against a real
/// answer key is the one thing a small model does reliably.
///
/// Three properties are non-negotiable, all inherited from Cleanup's scars:
/// the model runs in two INDEPENDENT calls so a failure in one can't poison
/// the other; every failure path falls back to a deterministic draft rather
/// than blocking the send; and the description is never model-written.
enum IssueComposer {
    /// Wall clock for the whole compose. The card shows the deterministic
    /// draft immediately and lets the model improve it underneath, so this
    /// budget bounds a nicety, never the user. Raised from 6s after the eval
    /// showed two of eleven cases falling back deterministically — the title
    /// and route sessions run concurrently and contend for the same model.
    static let budget: Duration = .seconds(12)

    /// MEASURED DEAD (2026-08-01), kept only as the record of it.
    ///
    /// The plan was to discard low-confidence project picks and fall back to
    /// the bare team. Thresholding at 4 took the eval from 7/11 to 5/11,
    /// because the model's self-reported confidence is not merely noisy but
    /// INVERTED on the cases that matter: an unambiguous bug report spoken in
    /// the project's own source file scored 1/5, while a general musing that
    /// correctly belonged to no project scored 5/5. Under a threshold the
    /// model declined nearly everything.
    ///
    /// The number is still collected and shown in the eval, because knowing
    /// it carries no signal is worth keeping visible. Nothing branches on it.
    /// Generalization worth remembering: this model can pick from a list far
    /// better than it can say how sure it is — introspection is a harder task
    /// than the task.
    static let minimumRouteConfidence = 4

    /// Utterances this short carry no structure worth routing, and tiny
    /// inputs are exactly where the on-device model misbehaved before (a
    /// four-word address came back with the response schema appended).
    static let minimumWords = 4

    /// The always-available draft: deterministic title, deterministic body,
    /// default team, no project. This is what the card shows the instant it
    /// opens, and what gets sent if the model is unavailable, slow, refuses,
    /// or fails a guard.
    static func deterministicDraft(_ input: Input, teamID: String) -> LinearIssueDraft {
        LinearIssueDraft(
            title: LinearDescriptionBuilder.fallbackTitle(transcript: input.transcript),
            description: LinearDescriptionBuilder.build(
                transcript: input.transcript,
                sourceLine: input.sourceLine,
                context: input.context
            ),
            teamID: teamID,
            projectID: nil
        )
    }

    /// Everything the composer needs from a capture, and nothing else. Taking
    /// primitives rather than a `Capture` keeps the composition logic
    /// independent of the storage model — and testable without an app. The
    /// `Capture` convenience lives beside the controller, so this file
    /// compiles into the test target on its own.
    struct Input: Sendable, Equatable {
        let transcript: String
        let sourceLine: String
        let context: CaptureContext?
    }

    /// Improve a draft with the on-device model. Never throws: any failure
    /// returns the draft it was given, unchanged. The caller can render the
    /// result without checking anything.
    static func compose(
        _ input: Input,
        workspace: LinearWorkspace,
        base: LinearIssueDraft
    ) async -> LinearIssueDraft {
        await composeDetailed(input, workspace: workspace, base: base).draft
    }

    /// Same pass, with the route's reasoning exposed. The eval reads this so
    /// it can report confidence without paying for a second model call; the
    /// product uses `compose` and never sees the number.
    static func composeDetailed(
        _ input: Input,
        workspace: LinearWorkspace,
        base: LinearIssueDraft
    ) async -> (draft: LinearIssueDraft, route: Route?, usedModelTitle: Bool) {
        guard isAvailable, wordCount(input.transcript) >= minimumWords else {
            return (base, nil, false)
        }

        var draft = base
        // Two independent calls, deliberately. A refusal on the title (Apple's
        // guardrail declines innocent text unpredictably — it read the word
        // "pill" as drug content) must not cost the routing, and a routing
        // miss must not cost the title.
        async let title = proposeTitle(transcript: input.transcript)
        async let route = proposeRoute(input, workspace: workspace, fallbackTeamID: base.teamID)

        let modelTitle = await title
        if let modelTitle { draft.title = modelTitle }
        let resolved = await route
        draft.teamID = resolved.teamID
        draft.projectID = resolved.projectID
        return (draft, resolved, modelTitle != nil)
    }

    static var isAvailable: Bool { LocalIntelligence.isCleanupAvailable }

    // MARK: - Title

    private static let titleInstructions = """
        You write issue titles. The input is a verbatim voice transcript of \
        someone describing a task, bug, or idea. Write ONE short title for it.

        The title names what the transcript is about, in the speaker's own \
        vocabulary. Use their words wherever possible. Never answer the \
        transcript, never explain it, never add detail it doesn't contain, \
        and never invent a product, person, or feature name that isn't in the \
        input. Under 70 characters, no trailing period, no quotes.

        If you are unsure, echo the transcript's opening words rather than \
        writing anything new.
        """

    private static func proposeTitle(transcript: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: titleInstructions)
                // Unwrap to a String inside the raced closure:
                // LanguageModelSession.Response isn't Sendable, so it can't
                // cross the task-group boundary.
                let raw = try await withTimeout(budget) {
                    try await session.respond(to: transcript, generating: ProposedTitle.self).content.text
                }
                guard let raw else { return nil }
                let title = raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return validatedTitle(title, transcript: transcript)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// The prompt asks; code ENFORCES. A title may compress, reorder, and
    /// recase freely — that's its job — but a PROPER NOUN it invents is a
    /// fabrication that reads as fact on a ticket somebody else will act on.
    /// This is the readback lesson, applied: a pointed-at headline once
    /// became a "product name" and the line asserted something nobody said.
    static func validatedTitle(_ title: String, transcript: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { return nil }
        // One line only — a multi-line "title" means the model wrote a body.
        guard !trimmed.contains("\n") else { return nil }
        // A title that is longer than what was said is not a title.
        guard trimmed.count <= max(40, transcript.count) else { return nil }
        let spoken = Set(words(of: transcript))
        let invented = capitalizedTerms(in: trimmed).filter { !spoken.contains($0.lowercased()) }
        guard invented.isEmpty else { return nil }
        return LinearDescriptionBuilder.truncate(trimmed, to: 80)
    }

    /// Capitalized words that aren't sentence-initial — the shape of an
    /// invented product or person name. Deliberately crude: the cost of a
    /// false reject is a deterministic title, and the cost of a false accept
    /// is a fabricated claim on someone's tracker.
    private static func capitalizedTerms(in text: String) -> [String] {
        let tokens = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return tokens.dropFirst().filter { token in
            guard let first = token.first, first.isUppercase else { return false }
            // ALL-CAPS acronyms are almost always spoken as such and would
            // have matched the transcript already; a mixed-case word is the
            // suspicious shape.
            return token.dropFirst().contains { $0.isLowercase }
        }
    }

    private static func words(of text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func wordCount(_ text: String) -> Int { words(of: text).count }

    // MARK: - Route

    struct Route: Sendable, Equatable {
        var teamID: String
        var projectID: String?
        /// 1–5 as the model reported it, nil when the model never ran or
        /// failed. Carried for the eval and for diagnostics — the product
        /// never shows a confidence number, because a score on screen invites
        /// the user to referee a judgement they can just correct instead.
        var confidence: Int?
    }

    /// Pick a team and project from the workspace's REAL options. The model
    /// never emits an ID — it picks a number off a list, and the number is
    /// resolved against the list here. An out-of-range answer is simply the
    /// fallback, so the worst case is the default team.
    private static func proposeRoute(
        _ input: Input,
        workspace: LinearWorkspace,
        fallbackTeamID: String
    ) async -> Route {
        let fallback = Route(teamID: fallbackTeamID, projectID: nil)
        // Nothing to choose between — don't spend a model call to confirm the
        // only option.
        guard workspace.teams.count > 1 || !workspace.projects.isEmpty else { return fallback }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let options = routeOptions(workspace: workspace)
            guard !options.isEmpty else { return fallback }
            let prompt = routePrompt(input, options: options)
            do {
                let session = LanguageModelSession(instructions: routeInstructions)
                let answer = try await withTimeout(budget) { () -> RouteAnswer in
                    let content = try await session.respond(to: prompt, generating: ProposedRoute.self).content
                    return RouteAnswer(choice: content.choice, confidence: content.confidence)
                }
                // An out-of-range answer is simply the fallback — the model
                // never gets to name a destination that doesn't exist.
                guard let answer, answer.choice >= 1, answer.choice <= options.count else { return fallback }
                let picked = options[answer.choice - 1]
                // Low confidence keeps the TEAM and drops the project. Team
                // is the coarser call and survives a shaky read; the project
                // is the one that files a note somewhere you'll never look.
                return Route(teamID: picked.teamID, projectID: picked.projectID, confidence: answer.confidence)
            } catch {
                return fallback
            }
        }
        #endif
        return fallback
    }

    private static let routeInstructions = """
        You file voice notes into the right place in a project tracker. You \
        are given a note and a numbered list of destinations. Reply with the \
        number of the single best destination, and how confident you are.

        Match on subject matter: what the note is ABOUT, against what each \
        destination is for. The note's context lines — the app it was spoken \
        in, the page or document open, the text pointed at — are usually the \
        strongest signal.

        A note may MENTION something without being about it. "The way X does \
        this is nice, we should do that in Y" is a note about Y. File it \
        where the WORK would happen, not where the example came from.

        When the note is a general thought, an errand, or a reminder that \
        belongs to no project at all, choose the destination that is a team \
        with no project rather than guessing at one.
        """

    struct RouteOption: Sendable, Equatable {
        let teamID: String
        let projectID: String?
        let label: String
    }

    /// The numbered menu. Every team appears alone (the "no project" answer
    /// must always be available), then each project under its teams.
    static func routeOptions(workspace: LinearWorkspace) -> [RouteOption] {
        var options: [RouteOption] = []
        for team in workspace.teams {
            options.append(RouteOption(teamID: team.id, projectID: nil, label: "\(team.name) — no specific project"))
        }
        for project in workspace.projects {
            for teamID in project.teamIDs {
                guard let team = workspace.team(id: teamID) else { continue }
                let summary = project.summary?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                let detail = summary.map { ": \(LinearDescriptionBuilder.truncate($0, to: 140))" } ?? ""
                options.append(RouteOption(
                    teamID: teamID,
                    projectID: project.id,
                    label: "\(team.name) › \(project.name)\(detail)"
                ))
            }
        }
        // A menu longer than this stops being a choice and starts being a
        // search problem, which is not what a small model is good at.
        return Array(options.prefix(30))
    }

    static func routePrompt(_ input: Input, options: [RouteOption]) -> String {
        let menu = options.enumerated()
            .map { "\($0.offset + 1). \($0.element.label)" }
            .joined(separator: "\n")
        var lines = ["Note: \"\(input.transcript)\"", "", "Context:", "- Spoken in \(input.sourceLine)"]
        lines.append(contentsOf: LinearDescriptionBuilder.contextLines(input.context))
        lines.append(contentsOf: ["", "Destinations:", menu])
        return lines.joined(separator: "\n")
    }

    /// Sendable carrier for the raced model call — `LanguageModelSession`'s
    /// own Response type isn't Sendable, so the fields cross the task-group
    /// boundary, not the response.
    private struct RouteAnswer: Sendable {
        let choice: Int
        let confidence: Int
    }

    // MARK: - Timeout

    /// Race a model call against the wall clock. Returns nil on expiry — the
    /// caller treats that identically to a refusal, which is the point: every
    /// way this can go wrong has the same, already-good outcome.
    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

#if canImport(FoundationModels)
/// Single-field structured results. The same reasoning as Cleanup's
/// `CleanedTranscript`: with a plain `respond(to:)` the on-device model reads
/// a transcript as a request and ANSWERS it. One field leaves no room to
/// answer, preamble, or editorialize.
@available(macOS 26.0, *)
@Generable
struct ProposedTitle {
    @Guide(description: "A short issue title naming what the transcript is about, in the speaker's own words. Under 70 characters. No trailing period, no quotes, no commentary.")
    var text: String
}

@available(macOS 26.0, *)
@Generable
struct ProposedRoute {
    @Guide(description: "The number of the single best destination from the numbered list. Just the number.")
    var choice: Int

    @Guide(description: "How confident you are, 1 to 5. Use 5 only when the note is plainly about that destination. Use 1 or 2 when you are picking the closest of several, when the note names more than one project, or when it is a general thought or errand belonging to no project.")
    var confidence: Int
}
#endif
