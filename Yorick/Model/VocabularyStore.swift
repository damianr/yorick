import Foundation

/// The user's vocabulary as persisted. Lives in UserDefaults (it's small) so
/// the transcription engines, which run off the main actor, read it directly
/// and every dictation sees the latest list.
enum VocabularyDefaults {
    static let entriesKey = "vocabularyEntries"
    static let suggestionsKey = "vocabularySuggestions"
    static let dismissedKey = "vocabularyDismissed"
    static let learnFromFixesKey = "vocabularyLearnFromFixes"

    /// The names hard-coded into the Whisper prompt before the vocabulary
    /// was the user's. Existing installs inherit them so their transcripts
    /// don't regress; fresh installs start empty.
    static let legacyTerms = ["InfuseFlow", "Yorick", "Claude", "Claude Code", "SafeYum", "Supabase", "SwiftUI", "Xcode"]

    /// Whisper reads only the first ~224 tokens of its prompt; past that the
    /// newest words would silently fall off the end.
    private static let maxPromptCharacters = 600

    static func entries() -> [VocabularyEntry] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: entriesKey) else {
            let seeded = defaults.bool(forKey: "hasCompletedOnboarding")
                ? legacyTerms.map { VocabularyEntry(term: $0, addedAt: .distantPast) }
                : []
            save(seeded)
            return seeded
        }
        return (try? JSONDecoder().decode([VocabularyEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [VocabularyEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: entriesKey)
    }

    /// Terms for the engines' biasing hints, newest first.
    static func terms() -> [String] {
        entries()
            .sorted { $0.addedAt > $1.addedAt }
            .map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Whisper's initial prompt: the terms as a comma list, nil when empty.
    static func whisperPrompt() -> String? {
        var prompt = ""
        for term in terms() {
            let next = prompt.isEmpty ? term : prompt + ", " + term
            if next.count > maxPromptCharacters { break }
            prompt = next
        }
        return prompt.isEmpty ? nil : prompt
    }

    /// On unless the user turned it off.
    static var learnsFromFixes: Bool {
        UserDefaults.standard.object(forKey: learnFromFixesKey) as? Bool ?? true
    }
}

/// The vocabulary for the UI: the list, the suggestions waiting on the user,
/// and the ones they've waved away (never offered again).
@MainActor
@Observable
final class VocabularyStore {
    static let shared = VocabularyStore()

    private(set) var entries: [VocabularyEntry]
    private(set) var suggestions: [VocabularySuggestion]
    private var dismissed: Set<VocabularySuggestion>

    private init() {
        let defaults = UserDefaults.standard
        entries = VocabularyDefaults.entries()
        suggestions = defaults.data(forKey: VocabularyDefaults.suggestionsKey)
            .flatMap { try? JSONDecoder().decode([VocabularySuggestion].self, from: $0) } ?? []
        dismissed = defaults.data(forKey: VocabularyDefaults.dismissedKey)
            .flatMap { try? JSONDecoder().decode(Set<VocabularySuggestion>.self, from: $0) } ?? []
    }

    /// Newest first, the order the settings list shows.
    var sortedEntries: [VocabularyEntry] {
        entries.sorted { $0.addedAt > $1.addedAt }
    }

    /// Add a term, or fold new heard-as spellings into the existing entry
    /// for it (terms match case-insensitively; the new casing wins).
    func add(term rawTerm: String, heardAs rawHeard: [String] = []) {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let heard = rawHeard
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != term }
        if let index = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
            entries[index].term = term
            for spelling in heard where !entries[index].heardAs.contains(where: { $0.caseInsensitiveCompare(spelling) == .orderedSame }) {
                entries[index].heardAs.append(spelling)
            }
        } else {
            var unique: [String] = []
            for spelling in heard where !unique.contains(where: { $0.caseInsensitiveCompare(spelling) == .orderedSame }) {
                unique.append(spelling)
            }
            entries.append(VocabularyEntry(term: term, heardAs: unique))
        }
        // A suggestion this addition already covers is answered.
        suggestions.removeAll { isCovered($0) }
        persist()
    }

    func remove(_ entry: VocabularyEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func removeHeardAs(_ spelling: String, from entry: VocabularyEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].heardAs.removeAll { $0 == spelling }
        persist()
    }

    /// Queue a suggestion. True when it's new — the caller then tells the
    /// user; false when it's already on the list, pending, or dismissed.
    @discardableResult
    func offer(_ suggestion: VocabularySuggestion) -> Bool {
        guard !dismissed.contains(suggestion),
              !suggestions.contains(suggestion),
              !isCovered(suggestion) else { return false }
        suggestions.append(suggestion)
        persist()
        return true
    }

    func accept(_ suggestion: VocabularySuggestion) {
        suggestions.removeAll { $0 == suggestion }
        // Casing-only fixes need no heard-as: the corrector re-cases
        // deliberately-cased terms by itself.
        let casingOnly = suggestion.heard.lowercased() == suggestion.term.lowercased()
        add(term: suggestion.term, heardAs: casingOnly ? [] : [suggestion.heard])
    }

    func dismiss(_ suggestion: VocabularySuggestion) {
        suggestions.removeAll { $0 == suggestion }
        dismissed.insert(suggestion)
        persist()
    }

    private func isCovered(_ suggestion: VocabularySuggestion) -> Bool {
        guard let entry = entries.first(where: { $0.term == suggestion.term }) else { return false }
        if suggestion.heard.lowercased() == suggestion.term.lowercased() { return true }
        return entry.heardAs.contains { $0.caseInsensitiveCompare(suggestion.heard) == .orderedSame }
    }

    private func persist() {
        VocabularyDefaults.save(entries)
        let defaults = UserDefaults.standard
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(suggestions) {
            defaults.set(data, forKey: VocabularyDefaults.suggestionsKey)
        }
        if let data = try? encoder.encode(dismissed) {
            defaults.set(data, forKey: VocabularyDefaults.dismissedKey)
        }
    }
}
