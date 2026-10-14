import Foundation

/// A word or name the user wants spelled their way: "Waits", not "weights".
///
/// The term itself is a HINT — every engine is biased toward it, but no
/// engine promises to honor it. `heardAs` is the GUARANTEE: whatever the
/// engine wrote, a heard-as spelling is swapped for the term after
/// transcription, the same on every engine.
struct VocabularyEntry: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var term: String
    /// What the engines write instead ("weights" for "Waits"). Matched as
    /// whole words, case-insensitively. Literal on purpose: once
    /// "weights → Waits" is a rule, every "weights" becomes "Waits".
    var heardAs: [String]
    var addedAt: Date

    init(id: UUID = UUID(), term: String, heardAs: [String] = [], addedAt: Date = Date()) {
        self.id = id
        self.term = term
        self.heardAs = heardAs
        self.addedAt = addedAt
    }
}

/// A heard-as rule Yorick noticed the user teaching it by hand: it typed
/// `heard`, and the user changed it to `term`.
struct VocabularySuggestion: Codable, Sendable, Hashable {
    let heard: String
    let term: String
}

// MARK: - Corrector

/// Deterministic post-transcription pass that makes the vocabulary stick
/// regardless of engine. Rules, not a model — same trade as
/// SpokenFormNormalizer: every rewrite is a whole-word match against
/// something the user explicitly put on their list.
enum VocabularyCorrector {

    static func apply(_ text: String, entries: [VocabularyEntry]) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }

        var rules: [(pattern: String, term: String)] = []
        for entry in entries {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            var spellings = Set(entry.heardAs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
            // "infuse flow" → "InfuseFlow": a camel-case term's spoken form
            // is its humps, and engines write the humps as separate words.
            if let spaced = spacedForm(of: term) { spellings.insert(spaced) }
            // Casing-only fix ("swiftui" → "SwiftUI") for terms whose casing
            // can't be a sentence-position accident. A plain capitalized name
            // never gets one — "Waits" must not eat the verb "waits".
            if hasDeliberateCasing(term) { spellings.insert(term) }
            for spelling in spellings {
                // A heard-as identical to the term in plain-capitalized
                // form would only ever re-case it; skip, per the rule above.
                if spelling.caseInsensitiveCompare(term) == .orderedSame, !hasDeliberateCasing(term) { continue }
                rules.append((pattern(for: spelling), term))
            }
        }
        // Longest first, so a multi-word spelling wins over a single word
        // inside it.
        rules.sort { $0.pattern.count > $1.pattern.count }

        var result = text
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.term)
            )
        }
        return result
    }

    /// Whole-word, whitespace-tolerant match for a spelling.
    private static func pattern(for spelling: String) -> String {
        let words = spelling.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        return #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
    }

    /// Internal capitals ("SwiftUI", "InfuseFlow", "iPhone") or an
    /// all-caps acronym ("NASA") — casing a speaker can't produce by
    /// starting a sentence.
    static func hasDeliberateCasing(_ term: String) -> Bool {
        guard !term.contains(where: \.isWhitespace) else { return false }
        let letters = term.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        return letters.dropFirst().contains(where: \.isUppercase)
    }

    /// "InfuseFlow" → "infuse flow", "SwiftUI" → "swift ui". Nil for terms
    /// without humps.
    static func spacedForm(of term: String) -> String? {
        guard !term.contains(where: \.isWhitespace) else { return nil }
        var parts: [String] = []
        var current = ""
        let chars = Array(term)
        for (i, ch) in chars.enumerated() {
            let prev: Character? = i > 0 ? chars[i - 1] : nil
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            // A hump starts at lower→Upper, or at the last capital of an
            // acronym run followed by lowercase ("XMLParser" → XML|Parser).
            let startsHump = ch.isUppercase && !current.isEmpty && (
                (prev?.isLowercase ?? false) ||
                ((prev?.isUppercase ?? false) && (next?.isLowercase ?? false))
            )
            if startsHump {
                parts.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        guard parts.count >= 2, parts.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) else { return nil }
        return parts.map { $0.lowercased() }.joined(separator: " ")
    }
}

// MARK: - Correction learner

/// Spots the user fixing a word Yorick typed. Given what was typed and what
/// the field says now, it aligns the two and reports single-spot
/// substitutions that SOUND like what was typed and LOOK like a name —
/// "weights" → "Waits". Grammar fixes ("their" → "there"), rewrites, and
/// typos in the other direction stay silent: a suggestion the user has to
/// wave away costs more than one we never make.
enum CorrectionLearner {

    /// Longest dictation worth watching, in words.
    static let maxTypedWords = 200
    /// Largest field worth aligning against, in words — beyond this it's a
    /// document, and the per-edit alignment isn't worth the cost.
    static let maxFieldWords = 4000

    /// Nil once the typed text is no longer recognizably in the field —
    /// the user sent it, cleared it, or rewrote it.
    static func suggestions(typed: String, current: String) -> [VocabularySuggestion]? {
        guard let alignment = align(typed: typed, current: current) else { return nil }
        var out: [VocabularySuggestion] = []
        for block in alignment.edits {
            guard let suggestion = suggestion(for: block, in: alignment.currentWords) else { continue }
            if !out.contains(suggestion) { out.append(suggestion) }
        }
        return out
    }

    // MARK: Alignment

    struct EditBlock: Equatable {
        let typed: [String]
        /// Range of the replacement in `currentWords`.
        let currentRange: Range<Int>
    }

    struct Alignment {
        let currentWords: [String]
        let edits: [EditBlock]
    }

    /// Semi-global word alignment: all of `typed` against the best-matching
    /// stretch of `current` (free gaps at either end of the field). Nil when
    /// under 60% of the typed words survive in place.
    static func align(typed: String, current: String) -> Alignment? {
        let a = words(typed)
        let b = words(current)
        guard !a.isEmpty, a.count <= maxTypedWords, !b.isEmpty, b.count <= maxFieldWords else { return nil }
        let ak = a.map { $0.lowercased() }
        let bk = b.map { $0.lowercased() }
        let m = a.count, n = b.count
        let width = n + 1

        // cost[i][j]: aligning a[0..<i] ending at b[j].
        var cost = [Int](repeating: 0, count: (m + 1) * width)
        for i in 1...m { cost[i * width] = i }
        for i in 1...m {
            for j in 1...n {
                let diag = cost[(i - 1) * width + j - 1] + (ak[i - 1] == bk[j - 1] ? 0 : 1)
                let up = cost[(i - 1) * width + j] + 1      // typed word deleted
                let left = cost[i * width + j - 1] + 1      // word inserted
                cost[i * width + j] = min(diag, up, left)
            }
        }
        var endJ = 0
        for j in 0...n where cost[m * width + j] < cost[m * width + endJ] { endJ = j }

        // Traceback into pair ops.
        enum Op { case match(Int, Int), sub(Int, Int), del(Int), ins(Int) }
        var ops: [Op] = []
        var i = m, j = endJ
        while i > 0 {
            let here = cost[i * width + j]
            if j > 0, here == cost[(i - 1) * width + j - 1] + (ak[i - 1] == bk[j - 1] ? 0 : 1) {
                ops.append(ak[i - 1] == bk[j - 1] ? .match(i - 1, j - 1) : .sub(i - 1, j - 1))
                i -= 1; j -= 1
            } else if here == cost[(i - 1) * width + j] + 1 {
                ops.append(.del(i - 1))
                i -= 1
            } else {
                ops.append(.ins(j - 1))
                j -= 1
            }
        }
        ops.reverse()

        var matches = 0
        var edits: [EditBlock] = []
        var pendingTyped: [String] = []
        var pendingStart: Int? = nil
        var pendingEnd = j  // where the region starts in `current`
        func flush() {
            if !pendingTyped.isEmpty || pendingStart != nil {
                let start = pendingStart ?? pendingEnd
                edits.append(EditBlock(typed: pendingTyped, currentRange: start..<pendingEnd))
            }
            pendingTyped = []
            pendingStart = nil
        }
        for op in ops {
            switch op {
            case let .match(ai, bj):
                flush()
                matches += 1
                // Case-only change ("swiftui" → "SwiftUI") is an edit too.
                if a[ai] != b[bj] {
                    edits.append(EditBlock(typed: [a[ai]], currentRange: bj..<(bj + 1)))
                }
                pendingEnd = bj + 1
            case let .sub(ai, bj):
                pendingTyped.append(a[ai])
                if pendingStart == nil { pendingStart = bj }
                pendingEnd = bj + 1
            case let .del(ai):
                pendingTyped.append(a[ai])
            case let .ins(bj):
                if pendingStart == nil { pendingStart = bj }
                pendingEnd = bj + 1
            }
        }
        flush()

        guard Double(matches) >= Double(m) * 0.6 else { return nil }
        return Alignment(currentWords: b, edits: edits)
    }

    private static func suggestion(for block: EditBlock, in currentWords: [String]) -> VocabularySuggestion? {
        let replaced = Array(currentWords[block.currentRange])
        guard (1...3).contains(block.typed.count), (1...3).contains(replaced.count) else { return nil }
        let heard = block.typed.joined(separator: " ")
        let term = replaced.joined(separator: " ")
        guard term.count <= 40, heard != term, term.contains(where: \.isLetter) else { return nil }

        // Must look like a name: some capital that isn't just the start of
        // a sentence. Keeps "their" → "there" and other grammar fixes quiet.
        let atSentenceStart: Bool = {
            let start = block.currentRange.lowerBound
            guard start > 0 else { return true }
            guard let last = currentWords[start - 1].last else { return true }
            return ".!?".contains(last)
        }()
        let capitalsAfterFirst = term.dropFirst().contains(where: \.isUppercase)
        let leadingCapital = term.first?.isUppercase ?? false
        let looksLikeName = capitalsAfterFirst || (leadingCapital && !atSentenceStart)
        guard looksLikeName else { return nil }

        if heard.lowercased() == term.lowercased() {
            // Casing-only: worth a rule only when the casing is deliberate
            // (the corrector already re-cases those terms on its own).
            return VocabularyCorrector.hasDeliberateCasing(term) ? VocabularySuggestion(heard: heard, term: term) : nil
        }
        guard soundsAlike(heard, term) else { return nil }
        return VocabularySuggestion(heard: heard, term: term)
    }

    // MARK: Words

    /// Whitespace-split words with edge punctuation trimmed (inner
    /// apostrophes and hyphens kept: "it's", "e-mail").
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: Sound

    /// Rough English sound-alike: compares consonant skeletons after folding
    /// common spellings of the same sound. "weights"/"Waits" → "wts"/"wts";
    /// "cloud"/"Claude" → "kld"/"kld".
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let x = skeleton(a), y = skeleton(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard x.first == y.first, min(x.count, y.count) >= 3 else { return false }
        return levenshtein(Array(x), Array(y)) <= 1
    }

    static func skeleton(_ text: String) -> String {
        var s = text.lowercased().filter { $0.isLetter && $0.isASCII }
        guard !s.isEmpty else { return "" }
        let folds: [(String, String)] = [
            ("tch", "ch"), ("sch", "sk"), ("ght", "t"), ("gh", ""), ("ph", "f"),
            ("ck", "k"), ("dg", "j"), ("wh", "w"), ("qu", "kw"), ("q", "k"),
            ("x", "ks"), ("ce", "se"), ("ci", "si"), ("cy", "sy"), ("c", "k"), ("z", "s"),
        ]
        if s.hasPrefix("kn") || s.hasPrefix("gn") || s.hasPrefix("wr") { s.removeFirst() }
        for (from, to) in folds { s = s.replacingOccurrences(of: from, with: to) }

        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y", "w", "h"]
        var out = ""
        for (index, ch) in s.enumerated() {
            if index == 0 {
                // A leading vowel is kept as one class: "Erin"/"Aaron".
                out.append(["a", "e", "i", "o", "u"].contains(ch) ? "a" : ch)
                continue
            }
            if vowels.contains(ch) { continue }
            if out.last == ch { continue }
            out.append(ch)
        }
        return out
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = row
        }
        return prev[b.count]
    }
}
