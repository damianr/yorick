import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Building an issue title out of what was on screen.
///
/// The premise, arrived at by failing twice: this model is bad at AUTHORING
/// and good at CHOOSING. Routing works because it picks from a real list.
/// Self-reported confidence failed because it needs introspection. Titles
/// failed twice — once lifting a sentence verbatim ("I don't really need this
/// section"), once writing something confidently wrong ("Emphasize Ums").
///
/// So nothing here asks it to write. A useful title is SUBJECT + ACTION, and
/// both halves already exist without a model: the subject is in the evidence
/// (a heading, the pointed element, a selection, the page), and the action is
/// what you said with the conversational scaffolding removed. Scaffolding is
/// a small closed set — "I want to…", "maybe we should…", "yeah so…" — which
/// makes it a rule, not a judgement.
///
/// Four strategies live here so they can be measured against each other
/// rather than argued about. See `IssueComposerEval`.
enum TitleComposer {

    enum Strategy: String, CaseIterable, Sendable {
        /// The model writes the title. Baseline; the thing being beaten.
        case modelAuthored
        /// No model at all: strip scaffolding, prefix the best subject.
        case deterministic
        /// Code assembles; the model only picks WHICH fact is the referent.
        case modelPicksSubject
        /// Code builds several whole candidates; the model picks one.
        case modelRanksCandidates
    }

    // MARK: - Subjects

    /// One thing the title could be ABOUT, with a rank for how good a name it
    /// is. Lower sorts first.
    struct Subject: Sendable, Equatable {
        let text: String
        let rank: Int
        /// Where it came from, for the eval and for the picker prompt.
        let provenance: String
    }

    /// Every nameable thing in the evidence, best first.
    ///
    /// The ordering is a claim about what names a thing well: a SECTION
    /// HEADING beats the paragraph under it, which beats a selection, which
    /// beats the page, which beats the file you were looking at. Each step
    /// down is a step further from "what the user meant" toward "where the
    /// user was."
    static func subjects(_ input: IssueComposer.Input, screenshotText: [String] = []) -> [Subject] {
        var found: [Subject] = []

        // 1. A heading the pointer sat under. ContextCollector writes these
        //    into the fact's detail as: role, under “Heading”.
        for fact in input.context?.facts ?? [] where fact.kind == "pointedElement" {
            if let heading = headingFromDetail(fact.detail) {
                found.append(Subject(text: heading, rank: 0, provenance: "heading"))
            }
        }

        // 2. Text the user FRAMED in a screenshot. Deliberately high: framing
        //    a region is the most explicit pointing gesture there is, and it
        //    reaches surfaces accessibility cannot (canvas, WebGL, images).
        for line in screenshotText.prefix(2) {
            found.append(Subject(text: line, rank: 1, provenance: "screenshot"))
        }

        // 3. The pointed element itself, when it's short enough to read as a
        //    name rather than a paragraph.
        for fact in input.context?.facts ?? [] where fact.kind == "pointedElement" {
            if isNameLike(fact.value) {
                found.append(Subject(text: fact.value, rank: 2, provenance: "pointed"))
            }
        }

        // 4. A short selection is a name; a long one is a quotation.
        for fact in input.context?.facts ?? [] where fact.kind == "selection" {
            if isNameLike(fact.value) {
                found.append(Subject(text: fact.value, rank: 3, provenance: "selection"))
            }
        }

        // 5. The page's own title.
        let pageTitle = LinearDescriptionBuilder.sanitizedWindowTitle(input.windowTitle)
        if isNameLike(pageTitle) {
            found.append(Subject(text: pageTitle, rank: 4, provenance: "page"))
        }

        // 6. The file or app, the weakest name — where you were, not what you
        //    meant. Kept because it beats nothing at all.
        if let tail = input.sourceLine.split(separator: "·").last.map(String.init) {
            let trimmed = tail.trimmingCharacters(in: .whitespaces)
            if isNameLike(trimmed), trimmed != pageTitle {
                found.append(Subject(text: trimmed, rank: 5, provenance: "source"))
            }
        }

        // Dedupe case-insensitively, keeping the best-ranked instance.
        var seen = Set<String>()
        return found
            .sorted { $0.rank < $1.rank }
            .filter { seen.insert($0.text.lowercased()).inserted }
    }

    /// `role, under “Heading”` → `Heading`.
    static func headingFromDetail(_ detail: String?) -> String? {
        guard let detail, let open = detail.range(of: "under “") else { return nil }
        let rest = detail[open.upperBound...]
        guard let close = rest.range(of: "”") else { return nil }
        let heading = String(rest[rest.startIndex..<close.lowerBound])
        return heading.isEmpty ? nil : heading
    }

    /// Short enough to be a NAME rather than a body of text. A 200-character
    /// paragraph is evidence; it is not what you call something.
    static func isNameLike(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 48 else { return false }
        return !trimmed.contains("\n")
    }

    // MARK: - Predicate

    /// Conversational scaffolding, stripped from the FRONT, repeatedly.
    ///
    /// A closed set, like the discourse markers splitting would need. People
    /// open spoken notes with a small number of stock phrases, and none of
    /// them belong in a title. Longest first so "maybe we should" is consumed
    /// before "maybe".
    static let openers: [String] = [
        "yeah so the thing is", "okay so the thing is", "so the thing is", "the thing is",
        "i would like to", "i'd like to", "i wanted to", "i want to", "i was thinking",
        "i keep thinking", "i just think", "i think that", "i think", "i thought",
        "i feel like", "i noticed that", "i noticed", "i just", "i don't know that",
        "maybe we should", "maybe we can", "maybe we could", "maybe",
        "we should probably", "we should", "we need to", "we could", "we might want to",
        "we have to", "let's just", "let's", "lets",
        "can we", "could we", "should we", "it would be good to", "it would be nice to",
        "it looks like", "it seems like", "it feels like", "it kind of",
        "one thing is", "another thing is", "note to self",
        "yeah so", "okay so", "ok so", "alright so", "right so", "so", "yeah", "okay", "ok",
        "um", "uh", "er", "like",
    ]

    /// Mid-sentence hedges that add nothing to a title.
    static let hedges: [String] = [
        "i feel like ", "i think ", "i guess ", "you know ", "kind of ", "sort of ",
        "just ", "really ", "probably ", "basically ", "actually ",
    ]

    /// What you said, made title-shaped without changing what it means.
    ///
    /// Everything here is subtractive. Nothing is rephrased, nothing is
    /// generated, so the output can be clunky but can never be WRONG — which
    /// is the property the model failed to hold.
    static func predicate(from transcript: String) -> String {
        var text = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // First sentence only; the rest is elaboration.
        if let end = text.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!")) {
            let first = String(text[text.startIndex..<end.lowerBound])
            // Unless it's tiny ("Hey."), in which case keep going.
            if first.count >= 12 { text = first }
        }


        // Peel openers until none match.
        var peeled = true
        while peeled {
            peeled = false
            let lowered = text.lowercased()
            for opener in openers {
                guard lowered.hasPrefix(opener) else { continue }
                // The opener has to end on a word boundary, or "so" eats
                // "software". A COMMA counts as one: people say "yeah so the
                // thing is, um, …", and matching only a following SPACE left
                // that entire preamble sitting in the title (measured).
                let rest = lowered.dropFirst(opener.count)
                if let next = rest.first, !" ,:;-—".contains(next) { continue }
                text = String(text.dropFirst(opener.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,-—:;"))
                peeled = true
                break
            }
        }

        for hedge in hedges {
            text = text.replacingOccurrences(of: hedge, with: "", options: [.caseInsensitive])
        }

        // Speech runs several clauses into one sentence with commas ("these
        // need to be consistent, half of them say one thing and half the
        // other"). The first clause carries the ask; the rest is evidence,
        // and it is already in the description.
        //
        // ORDER MATTERS, and getting it wrong is measurable: this ran BEFORE
        // the opener peeling at first, so "yeah so the thing is, um, I feel
        // like the onboarding copy…" truncated at the first comma to exactly
        // the scaffolding, which then peeled to nothing and fell back to the
        // raw transcript. Clauses can only be counted once the preamble is
        // gone.
        if text.count > 52, let comma = text.firstIndex(of: ",") {
            let head = String(text[text.startIndex..<comma])
            if head.count >= 16 { text = head }
        }

        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,-—:"))
        guard !text.isEmpty else { return LinearDescriptionBuilder.fallbackTitle(transcript: transcript) }
        return LinearDescriptionBuilder.truncate(sentenceCased(text), to: 72)
    }

    private static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Whether the predicate leans on something it doesn't name. Only then is
    /// a subject prefix worth its width — "The saved list needs an empty
    /// state" already says what it's about, and "MenuBarPanelView.swift — "
    /// in front of it is noise.
    ///
    /// `strongSubject` covers the second case, found by measurement: "wrong
    /// colour" contains no demonstrative at all, yet cannot stand alone as a
    /// title. A predicate that short is under-specified by definition — but
    /// it is only worth prefixing from a GOOD name (a heading, a framed
    /// region, the pointed element), never from "Terminal".
    static func needsSubject(_ predicate: String, strongSubject: Bool = false) -> Bool {
        let words = predicate.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let deictic: Set<String> = ["this", "these", "that", "those", "here", "there", "it", "them", "they"]
        if words.contains(where: { deictic.contains($0) }) { return true }
        return strongSubject && predicate.count <= 24
    }

    /// Prefixes whenever a subject is given. The DECISION belongs to the
    /// caller — this only assembles.
    static func assemble(subject: String?, predicate: String) -> String {
        guard let subject, !subject.isEmpty else {
            return LinearDescriptionBuilder.truncate(predicate, to: 80)
        }
        let name = LinearDescriptionBuilder.truncate(subject, to: 40)
        return LinearDescriptionBuilder.truncate("\(name) — \(lowercasedLead(predicate))", to: 88)
    }

    /// After a subject prefix the predicate reads as a continuation, so its
    /// sentence-cased first letter goes back down — unless it's a proper noun
    /// or an acronym, which stay as they are.
    private static func lowercasedLead(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let rest = text.dropFirst()
        if rest.first?.isUppercase == true { return text }  // acronym
        let firstWord = text.components(separatedBy: " ").first ?? ""
        // A capitalised word that also appears lowercase-able mid-sentence is
        // ordinary; leave known-proper shapes alone.
        if firstWord.count > 1, firstWord.dropFirst().contains(where: { $0.isUppercase }) { return text }
        return first.lowercased() + rest
    }

    // MARK: - Strategies

    /// Whole titles built in code, best first. The candidate list is also
    /// what `modelRanksCandidates` chooses from, so the model can only ever
    /// return something the deterministic path would have been willing to.
    static func candidates(_ input: IssueComposer.Input, screenshotText: [String] = []) -> [String] {
        let body = predicate(from: input.transcript)
        var out = [assemble(subject: nil, predicate: body)]
        for subject in subjects(input, screenshotText: screenshotText).prefix(3) where !subject.text.isEmpty {
            let candidate = assemble(subject: subject.text, predicate: body)
            if !out.contains(candidate) { out.append(candidate) }
        }
        // The rawest option stays on the list: sometimes what you said,
        // trimmed, is simply the best available title.
        let raw = LinearDescriptionBuilder.fallbackTitle(transcript: input.transcript)
        if !out.contains(raw) { out.append(raw) }
        return out
    }

    static func deterministicTitle(_ input: IssueComposer.Input, screenshotText: [String] = []) -> String {
        let body = predicate(from: input.transcript)
        let options = subjects(input, screenshotText: screenshotText)
        // rank <= 2 is a heading, framed text, or the pointed element — a
        // NAME. Below that is the page or the file, which say where you were
        // rather than what you meant.
        let strong = (options.first?.rank ?? 99) <= 2
        let subject = needsSubject(body, strongSubject: strong) ? options.first?.text : nil
        return assemble(subject: subject, predicate: body)
    }

    // MARK: Model-assisted

    private static let subjectInstructions = """
        You are told what someone said and given a numbered list of things \
        that were on their screen. Reply with the number of the thing they \
        were talking ABOUT.

        Prefer the most specific name: a section heading beats a paragraph \
        inside it, a row beats the table around it. If the note already names \
        its own subject and none of the options add anything, reply 0.
        """

    /// The model's ONLY job: say which fact is the referent. Code does the
    /// rest, so a wrong pick costs a wrong prefix — never a wrong meaning.
    static func subjectPickedTitle(_ input: IssueComposer.Input, screenshotText: [String] = []) async -> String {
        let body = predicate(from: input.transcript)
        let options = subjects(input, screenshotText: screenshotText)
        let strong = (options.first?.rank ?? 99) <= 2
        guard needsSubject(body, strongSubject: strong), !options.isEmpty else {
            return assemble(subject: nil, predicate: body)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let menu = options.enumerated()
                .map { "\($0.offset + 1). \($0.element.text)  (\($0.element.provenance))" }
                .joined(separator: "\n")
            let prompt = "Note: \"\(input.transcript)\"\n\nOn screen:\n\(menu)"
            if let choice = try? await IssueComposer.rawChoice(
                instructions: subjectInstructions, prompt: prompt
            ), choice >= 1, choice <= options.count {
                return assemble(subject: options[choice - 1].text, predicate: body)
            }
            // 0, out of range, refusal or timeout: the deterministic pick.
        }
        #endif
        return assemble(subject: options.first?.text, predicate: body)
    }

    private static let rankInstructions = """
        You are given a note someone spoke and a numbered list of candidate \
        issue titles for it. Reply with the number of the best one.

        The best title tells a reader scanning a list WHAT the issue is \
        about. A title naming a specific thing beats a vague one. A title \
        that is merely longer does not beat a shorter one that names the same \
        thing.
        """

    static func rankedTitle(_ input: IssueComposer.Input, screenshotText: [String] = []) async -> String {
        let options = candidates(input, screenshotText: screenshotText)
        guard options.count > 1 else { return options.first ?? "" }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let menu = options.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            let prompt = "Note: \"\(input.transcript)\"\n\nCandidate titles:\n\(menu)"
            if let choice = try? await IssueComposer.rawChoice(
                instructions: rankInstructions, prompt: prompt
            ), choice >= 1, choice <= options.count {
                return options[choice - 1]
            }
        }
        #endif
        return options[0]
    }
}
