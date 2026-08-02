import Foundation

/// What Yorick is about to send, exactly. Every field is visible on the card
/// before the press — the preview is the trust model, so this struct is
/// literally what the user approves.
struct LinearIssueDraft: Sendable, Equatable {
    var title: String
    var description: String
    /// Which connection creates this issue. A Linear token is scoped to ONE
    /// workspace, so the destination is only fully specified once this is
    /// known — and picking a team already picks it, since a team belongs to
    /// exactly one workspace.
    var workspaceID: String = ""
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

    static func build(
        transcript: String,
        sourceLine: String,
        windowTitle: String = "",
        context: CaptureContext?,
        screenshotCount: Int = 0
    ) -> String {
        let quoted = transcript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        var sections = [framing, "", quoted, "", "**Context**", ""]
        // In a browser, identity is carried by the Page and Page title lines
        // that `contextLines` emits — the source line there is just the raw
        // window title again, complete with whatever the browser appends.
        if !hasPageURL(context) {
            sections.append("- Spoken in \(sourceLine)")
        }
        sections.append(contentsOf: contextLines(context, windowTitle: windowTitle))
        // Named even before upload exists, so the issue is honest about what
        // the capture holds rather than silently leaving it on the Mac.
        if screenshotCount > 0 {
            sections.append("- \(screenshotCount) screenshot\(screenshotCount == 1 ? "" : "s") attached")
        }
        return sections.joined(separator: "\n")
    }

    static func hasPageURL(_ context: CaptureContext?) -> Bool {
        context?.facts.contains { $0.kind == "pageURL" && !$0.value.isEmpty } ?? false
    }

    /// The page's own title, with the browser's furniture removed.
    ///
    /// Browsers render "<page title> - <Browser> - <profile>", so truncating
    /// at the browser name takes the profile with it — which is the actual
    /// leak that started this ("- Google Chrome - damian" in every ticket).
    /// Cutting at a known browser name rather than guessing at trailing
    /// segments keeps it from eating real titles that contain dashes.
    static func sanitizedWindowTitle(_ title: String) -> String {
        var cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for browser in AppIdentifier.browsers {
            for separator in [" - ", " — ", " – "] {
                if let range = cleaned.range(of: separator + browser) {
                    cleaned = String(cleaned[cleaned.startIndex..<range.lowerBound])
                    break
                }
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the title says anything the URL doesn't.
    ///
    /// This is the whole reason both lines survive. A URL is a HANDLE and a
    /// title is a NAME, and which one carries meaning flips constantly:
    /// heyyorick.com explains itself while its title merely restates it, but
    /// localhost:3000, figma.com/file/aB3xQ, and drive.google.com/file/d/1a2b
    /// say nothing at all and the title is the only identity there is.
    /// Keeping both unless they genuinely agree costs one short line and
    /// removes a class of ticket nobody can place. Deliberately NOT a model
    /// call — "do these two strings say the same thing" has a right answer.
    static func titleIsRedundant(_ title: String, withURL url: String) -> Bool {
        let squashedTitle = alphanumerics(title)
        guard !squashedTitle.isEmpty else { return true }
        // Compare against the HOST only: a path segment matching the title is
        // normal ("/yorick") and doesn't make the title redundant.
        let host = alphanumerics(URLComponents(string: url)?.host ?? "")
        guard !host.isEmpty else { return false }
        // "heyyorick.com" vs "Yorick" — the shorter being inside the longer
        // means neither adds to the other.
        return host.contains(squashedTitle) || squashedTitle.contains(host)
    }

    private static func alphanumerics(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Evidence with provenance, one bullet per fact — never a summary.
    /// Yorick states what accessibility reported and lets the reader resolve
    /// the reference; interpreting it here would be the thing the whole
    /// design is built to avoid.
    static func contextLines(_ context: CaptureContext?, windowTitle: String = "") -> [String] {
        let facts = context?.facts ?? []
        guard !facts.isEmpty else { return [] }
        var lines: [String] = []
        var pointed: [String] = []
        for fact in facts {
            // A pointed element that merely restates the page or window title
            // is the sweep catching the document on its way somewhere, not a
            // referent. It reads as evidence and dilutes the fact that is.
            if fact.kind == "pointedElement", echoesDocumentTitle(fact.value, windowTitle: windowTitle) {
                continue
            }
            switch fact.kind {
            case "pageURL":
                lines.append("- Page: \(fact.value)")
                // The name beside the handle, when it adds one. On localhost,
                // an IP, or an opaque file id this is the only identity in
                // the whole payload.
                let title = sanitizedWindowTitle(windowTitle)
                if !title.isEmpty, !titleIsRedundant(title, withURL: fact.value) {
                    lines.append("- Page title: \(title)")
                }
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

    /// Whether a pointed value is really just the document's own title.
    /// Substring in either direction, because the window title carries
    /// browser furniture the pointed value doesn't, and vice versa. Short
    /// values are exempt: a button reading "Save" shouldn't vanish because
    /// the word appears in a window title.
    static func echoesDocumentTitle(_ value: String, windowTitle: String) -> Bool {
        let title = sanitizedWindowTitle(windowTitle).lowercased()
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty, candidate.count >= 12 else { return false }
        return title.contains(candidate) || candidate.contains(title)
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
