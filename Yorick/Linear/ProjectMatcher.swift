import Foundation

/// Deterministic evidence-to-project matching.
///
/// Built after the eval showed marketing-site captures failing on EVERY run.
/// The diagnosis in the todo ("the site project's description overlaps every
/// other project") was wrong. Both halves of the answer were already in the
/// prompt: the project's summary says "heyyorick.com" and the capture's
/// context says "Page: https://heyyorick.com/". The model simply wasn't
/// connecting them, while the word "Yorick" pulled it toward the product
/// project instead.
///
/// "Does this host appear in that project's description" has a right answer,
/// so it stops being a judgement call. Same rule that settled titles and the
/// URL-versus-window-title question: anything checkable is code, and the
/// model gets what's genuinely ambiguous.
enum ProjectMatcher {

    struct Match: Sendable, Equatable {
        let projectID: String
        let teamID: String
        /// Why it matched, for the eval and for diagnostics.
        let reason: String
    }

    /// Projects the evidence points at outright.
    ///
    /// Empty is the common case and means "ask the model." One match means
    /// there is nothing to ask. Several means the model chooses, but only
    /// among these — a shortlist it cannot escape.
    static func matches(_ input: IssueComposer.Input, workspace: LinearWorkspace) -> [Match] {
        var found: [Match] = []
        let facts = input.context?.facts ?? []

        // Hosts the capture was actually on. A URL is the least ambiguous
        // fact in the whole bundle: it is machine-written, not spoken, so it
        // can't be misheard, and a project that names a domain is telling you
        // exactly what it is for.
        let hosts = facts
            .filter { $0.kind == "pageURL" }
            .compactMap { URLComponents(string: $0.value)?.host?.lowercased() }
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }

        let spoken = words(input.transcript)
        let place = (input.sourceLine + " " + input.windowTitle).lowercased()

        for project in workspace.projects {
            guard let teamID = project.teamIDs.first else { continue }
            let haystack = (project.name + " " + (project.summary ?? "")).lowercased()

            // 1. The project names the domain you were on.
            if let host = hosts.first(where: { haystack.contains($0) }) {
                found.append(Match(projectID: project.id, teamID: teamID, reason: "host:\(host)"))
                continue
            }
            // 2. You said the project's name. Whole words, so "Admin" doesn't
            //    match "administrator" and a one-word project doesn't match
            //    half the dictionary.
            let nameWords = words(project.name)
            if !nameWords.isEmpty, nameWords.allSatisfy({ spoken.contains($0) }) {
                found.append(Match(projectID: project.id, teamID: teamID, reason: "named"))
                continue
            }
            // 3. The project's name is in the file or window you were in —
            //    weaker, because being somewhere isn't the same as talking
            //    about it, but a repo or page named for a project is a strong
            //    hint in practice.
            //
            //    WORD BOUNDARIES, not substrings. Measured: a plain
            //    `contains` matched the project "Yorick" inside the host
            //    "heyyorick.com", so a capture on the marketing site matched
            //    BOTH projects and stopped being decidable.
            if project.name.count >= 4, containsWord(place, project.name.lowercased()) {
                found.append(Match(projectID: project.id, teamID: teamID, reason: "place"))
            }
        }
        // Precedence: a host match is a project SAYING what it is for, and
        // it beats every weaker signal outright. Without this, one incidental
        // place match is enough to turn a decided answer back into a guess.
        let decisive = found.filter(isDecisive)
        return decisive.isEmpty ? found : decisive
    }

    /// Whole-word containment. `place` is a sentence of app and window names,
    /// so a substring test finds project names inside unrelated words.
    private static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        let tokens = haystack
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let needleTokens = needle
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !needleTokens.isEmpty else { return false }
        return needleTokens.allSatisfy { tokens.contains($0) }
    }

    /// Whether a single match is trustworthy enough to skip the model.
    ///
    /// Only a HOST match earns that. A domain in a project description is an
    /// explicit statement of what the project is for; a name appearing in a
    /// transcript can be a mention rather than a subject ("the way Railbird
    /// does its empty states is nice, we should do that in the saved list"),
    /// which the eval already caught the model getting wrong.
    static func isDecisive(_ match: Match) -> Bool {
        match.reason.hasPrefix("host:")
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 })
    }
}
