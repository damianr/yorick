import Foundation

/// Deterministic spoken-form normalization: dictated email and web addresses
/// land as symbols ("damian at gmail dot com" → damian@gmail.com).
///
/// Rules, not a model. Every rewrite is anchored to a tight token grammar —
/// a run only matches when it ends in a known TLD — and validated before it's
/// committed; anything ambiguous is emitted exactly as spoken. Under-normalizing
/// beats inventing, the same trade Cleanup settled. This corrects transcription
/// artifacts (like punctuation), so it applies to every utterance, not just
/// field insertions.
enum SpokenFormNormalizer {

    /// Applies every rule once. Whitespace, punctuation, and casing outside a
    /// matched run are untouched, so multi-line dictations survive intact
    /// (token separators are spaces/tabs only, never newlines).
    static func normalize(_ text: String) -> String {
        var result = rewrite(text, pattern: emailPattern, transform: assembleEmail)
        result = rewrite(result, pattern: webPattern, transform: assembleWebAddress)
        return result
    }

    // MARK: - Patterns

    /// The TLD alternation is embedded in the pattern, not just checked after:
    /// a candidate that can't end in a known TLD must never MATCH, or a failed
    /// greedy prefix ("email me at damian…") would consume the region and mask
    /// the real address behind it ("…at gmail dot com").
    private static let tldAlternation = knownTLDs.sorted().joined(separator: "|")

    private static let boundaryStart = #"(?:^|(?<=[\s(]))"#
    private static let boundaryEnd = #"(?=$|[\s.,;:!?)])"#

    /// local (dot|underscore|dash|plus local)* at domain… dot TLD
    /// The domain is either spoken ("gmail dot com") or already literal
    /// ("gmail.com" — SpeechAnalyzer sometimes writes the dot itself).
    private static let emailPattern =
        #"(?i)"# + boundaryStart
        + #"(?<local>[\p{L}\p{N}]+(?:[ \t]+(?:dot|underscore|dash|hyphen|plus)[ \t]+[\p{L}\p{N}]+)*)"#
        + #"[ \t]+at[ \t]+"#
        + #"(?<domain>[\p{L}\p{N}][\p{L}\p{N}\-]*(?:[ \t]+dot[ \t]+[\p{L}\p{N}\-]+)*[ \t]+dot[ \t]+(?:@TLD@)"#
        + #"|(?:[\p{L}\p{N}\-]+\.)+(?:@TLD@))"#
        + boundaryEnd

    /// (www dot)? domain (dot label)* dot TLD (slash segment)*
    /// Requires at least one SPOKEN "dot", so text that already contains a
    /// written domain is left alone.
    private static let webPattern =
        #"(?i)"# + boundaryStart
        + #"(?<www>www(?:[ \t]+dot[ \t]+|\.))?"#
        + #"(?<domain>[\p{L}\p{N}][\p{L}\p{N}\-]*(?:[ \t]+dot[ \t]+[\p{L}\p{N}\-]+)*[ \t]+dot[ \t]+(?:@TLD@))"#
        + #"(?<path>(?:[ \t]+slash[ \t]+[\p{L}\p{N}\-_.]+)*)"#
        + boundaryEnd

    // MARK: - Assembly

    private static func assembleEmail(_ groups: [String: String]) -> String? {
        guard let localTokens = groups["local"], let domainTokens = groups["domain"] else { return nil }
        // "the article at nytimes dot com" is a web reference, not an email —
        // a function-word or common-referent local part means "at" was the
        // preposition. Leave it as spoken; the web rule still fixes the domain.
        let localWords = tokenize(localTokens)
        guard let last = localWords.last, !emailLocalStopwords.contains(last.lowercased()) else { return nil }
        let local = localWords.map(symbolForConnector).joined()
        guard let domain = joinDomain(domainTokens) else { return nil }
        let candidate = "\(local)@\(domain)"
        return isStructurallyValid(candidate, kind: .email) ? candidate : nil
    }

    private static func assembleWebAddress(_ groups: [String: String]) -> String? {
        guard let domainTokens = groups["domain"],
              let domain = joinDomain(domainTokens),
              let firstLabel = domain.split(separator: ".").first,
              !stopwordLabels.contains(firstLabel.lowercased())
        else { return nil }
        let www = groups["www"] == nil ? "" : "www."
        var path = ""
        for token in tokenize(groups["path"] ?? "") {
            switch token.lowercased() {
            case "slash": path += "/"
            case "dot": path += "."
            case "dash", "hyphen": path += "-"
            case "underscore": path += "_"
            default: path += token.lowercased()
            }
        }
        let candidate = www + domain + path
        return isStructurallyValid(candidate, kind: .webAddress) ? candidate : nil
    }

    private static func tokenize(_ run: String) -> [String] {
        run.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private static func symbolForConnector(_ token: String) -> String {
        switch token.lowercased() {
        case "dot": return "."
        case "underscore": return "_"
        case "dash", "hyphen": return "-"
        case "plus": return "+"
        default: return token
        }
    }

    /// Joins a domain run, lowercased by convention. Nil unless the result is
    /// domain-shaped with a known final TLD — belt-and-braces behind the
    /// pattern's own TLD gate.
    private static func joinDomain(_ tokens: String) -> String? {
        let out = tokenize(tokens)
            .map { $0.lowercased() == "dot" ? "." : $0.lowercased() }
            .joined()
        let labels = out.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              let tld = labels.last.map(String.init),
              knownTLDs.contains(tld),
              labels.allSatisfy({ !$0.isEmpty && $0.first != "-" && $0.last != "-" })
        else { return nil }
        return out
    }

    /// Final gate: the assembled candidate must be shaped exactly like the
    /// thing we claim it is. Structural, not NSDataDetector — the detector's
    /// TLD table lags reality (verified: it rejects "linear.app"), and a gate
    /// that silently blocks modern TLDs fails the addresses this user
    /// dictates most.
    private enum CandidateKind { case email, webAddress }

    private static func isStructurallyValid(_ candidate: String, kind: CandidateKind) -> Bool {
        let domainPart = #"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}"#
        let pattern: String
        switch kind {
        case .email:
            pattern = #"^[A-Za-z0-9](?:[A-Za-z0-9._+-]*[A-Za-z0-9])?@"# + domainPart + "$"
        case .webAddress:
            pattern = "^(?:www\\.)?" + domainPart + #"(?:/[a-z0-9._~-]+)*$"#
        }
        return candidate.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Regex plumbing

    /// Replaces each match with `transform`'s output (skipping the match when
    /// it returns nil), walking back-to-front so ranges stay valid. Regexes
    /// are compiled per call — utterances arrive seconds apart, and immutable
    /// statics don't survive strict concurrency without unsafe annotations.
    private static func rewrite(
        _ text: String,
        pattern: String,
        transform: ([String: String]) -> String?
    ) -> String {
        let expanded = pattern.replacingOccurrences(of: "@TLD@", with: tldAlternation)
        guard let regex = try? NSRegularExpression(pattern: expanded) else {
            assertionFailure("SpokenFormNormalizer pattern failed to compile")
            return text
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        var result = text
        for match in regex.matches(in: text, range: fullRange).reversed() {
            var groups: [String: String] = [:]
            for name in ["local", "domain", "www", "path"] {
                let r = match.range(withName: name)
                if r.location != NSNotFound, let swiftRange = Range(r, in: text) {
                    groups[name] = String(text[swiftRange])
                }
            }
            guard let replacement = transform(groups),
                  let matchRange = Range(match.range, in: result)
            else { continue }
            result.replaceSubrange(matchRange, with: replacement)
        }
        return result
    }

    // MARK: - Word lists

    /// Final local-part words that mean "at" was a preposition, not an @ —
    /// "the article at nytimes dot com" and "docs are at swift dot org" are
    /// site references, not addresses. Favor the preposition when in doubt:
    /// the web rule still fixes the domain, and under-normalizing an email
    /// beats inventing one.
    private static let emailLocalStopwords: Set<String> = [
        // function words
        "the", "a", "an", "this", "that", "these", "those", "it", "them",
        "you", "me", "him", "her", "us", "one", "here", "there", "over",
        "out", "up", "now", "more",
        // verbs that precede a location reference
        "is", "are", "was", "were", "be", "been", "being", "am", "get",
        "go", "went", "visit", "see", "saw", "check", "find", "found",
        "look", "live", "lives", "living", "hosted", "posted", "published",
        "available", "online",
        // things that live at a URL
        "article", "page", "post", "video", "talk", "story", "site",
        "website", "homepage", "blog", "stuff", "thing", "things", "list",
        "docs", "documentation", "guide", "details", "info",
    ]

    /// Domain labels that read as ordinary speech before "dot com" — "the
    /// dot com era" must never become the.com.
    private static let stopwordLabels: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your",
        "his", "her", "its", "our", "their", "any", "some", "no", "one",
        "said", "was", "is", "are", "be", "so", "and", "or", "of", "to",
    ]

    /// Deliberately common-only. A missing TLD means an address stays as
    /// spoken — the cheap, honest failure.
    private static let knownTLDs: Set<String> = [
        "com", "net", "org", "edu", "gov", "mil", "int", "io", "co", "ai",
        "app", "dev", "me", "us", "uk", "ca", "de", "fr", "es", "it", "nl",
        "se", "no", "dk", "fi", "ch", "be", "pl", "pt", "gr", "cz", "ru",
        "jp", "cn", "kr", "in", "br", "mx", "au", "nz", "ie", "tv", "cc",
        "fm", "gg", "ly", "sh", "to", "xyz", "info", "biz", "tech",
        "online", "site", "studio", "cloud", "email", "computer",
    ]
}
