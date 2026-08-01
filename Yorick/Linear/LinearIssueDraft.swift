import Foundation

/// What Yorick is about to send, exactly. Every field is visible on the card
/// before the press — the preview is the trust model, so this struct is
/// literally what the user approves.
struct LinearIssueDraft: Sendable, Equatable {
    var title: String
    var description: String
    var teamID: String
    var projectID: String?
}

struct LinearCreatedIssue: Codable, Sendable, Equatable {
    let id: String
    /// "ENG-142" — what the card shows.
    let identifier: String
    let url: String
    let title: String
}

/// The description body. DETERMINISTIC — a template, never model-written.
///
/// Inherited whole from the enrichment plan and unchanged in its reasoning: a
/// cold receiver can't otherwise know the quoted block is verbatim speech
/// rather than a message addressed to them, which is the exact failure
/// Cleanup measured when the on-device model answered a transcript instead of
/// editing it. The framing line is fixed so that failure can't recur here.
enum LinearDescriptionBuilder {
    static let framing = "Captured by voice. The quoted words are a verbatim transcript — "
        + "resolve any \"this\", \"here\", or \"these\" against the context below."

    static func build(transcript: String, sourceLine: String, context: CaptureContext?) -> String {
        let quoted = transcript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        var sections = [framing, "", quoted, "", "**Context**", "", "- Spoken in \(sourceLine)"]
        sections.append(contentsOf: contextLines(context))
        return sections.joined(separator: "\n")
    }

    /// Evidence with provenance, one bullet per fact — never a summary.
    /// Yorick states what accessibility reported and lets the reader resolve
    /// the reference; interpreting it here would be the thing the whole
    /// design is built to avoid.
    static func contextLines(_ context: CaptureContext?) -> [String] {
        let facts = context?.facts ?? []
        guard !facts.isEmpty else { return [] }
        var lines: [String] = []
        var pointed: [String] = []
        for fact in facts {
            switch fact.kind {
            case "pageURL":
                lines.append("- Page: \(fact.value)")
            case "document":
                // Chrome answers AXDocument with the page URL; a duplicate
                // line is noise for the receiver.
                if !facts.contains(where: { $0.kind == "pageURL" && $0.value == fact.value }) {
                    lines.append("- Document: \(fact.value)")
                }
            case "selection":
                lines.append("- Selected text: \"\(fact.value)\"")
            case "pointedElement":
                let role = fact.detail.map { " (\($0))" } ?? ""
                pointed.append("\(fact.value)\(role)")
            default:
                lines.append("- \(fact.kind): \(fact.value)")
            }
        }
        // Pointing is a gesture, not a moment: the sweep renders in order, so
        // "this whole section" arrives as its rows rather than one frozen word.
        if pointed.count == 1 {
            lines.append("- Pointed at: \(pointed[0])")
        } else if pointed.count > 1 {
            lines.append("- Pointed at while speaking, in order:")
            lines.append(contentsOf: pointed.map { "  - \($0)" })
        }
        return lines
    }

    /// The deterministic title, used whenever the model is unavailable,
    /// refuses, times out, or fails a guard. Sentence-shaped and capped —
    /// good enough that a failed compose still produces a legible issue,
    /// which is what lets the composer fail silently.
    static func fallbackTitle(transcript: String) -> String {
        let collapsed = transcript
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "Voice capture" }
        // First sentence if there is one and it isn't tiny; otherwise the
        // opening words. Never mid-word.
        let firstSentence = collapsed.prefix { $0 != "." && $0 != "?" && $0 != "!" }
        let candidate = firstSentence.count >= 15 ? String(firstSentence) : collapsed
        return truncate(candidate, to: 80)
    }

    /// Cap at a word boundary with an ellipsis, so a long capture doesn't
    /// produce a title that stops mid-syllable.
    static func truncate(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let clipped = String(trimmed.prefix(limit))
        if let lastSpace = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: lastSpace) > limit / 2 {
            return String(clipped[clipped.startIndex..<lastSpace]) + "…"
        }
        return clipped + "…"
    }
}
