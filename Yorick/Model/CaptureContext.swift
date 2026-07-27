import Foundation

/// One verbatim piece of evidence gathered around an utterance — what was
/// selected, what page was open, what the pointer touched. Facts, never
/// inferences: the value is exactly what accessibility reported (length-
/// capped), with provenance, so a later consumer — usually another LLM —
/// resolves references itself. Yorick never interprets.
struct ContextFact: Codable, Sendable, Equatable {
    /// "selection" | "pageURL" | "document" | "pointedElement"
    let kind: String
    /// Verbatim value, capped at collection time.
    let value: String
    /// Where it came from (element role etc.) — provenance, shown on request.
    let detail: String?
    /// "start" (hotkey down) or "stop" (release) — pointing happens while
    /// talking, so both snapshots matter and the delta is itself evidence.
    let phase: String
}

/// The evidence bundle attached to a capture. Versioned so the schema can
/// grow without stranding old records; absence (nil on Capture) is normal
/// and means collection found nothing beyond app + window title.
struct CaptureContext: Codable, Sendable, Equatable {
    let version: Int
    let facts: [ContextFact]

    init(version: Int = 1, facts: [ContextFact]) {
        self.version = version
        self.facts = facts
    }

    /// Start and stop snapshots merged: start-phase facts win (the plan's
    /// "freeze the semantic target at trigger"), stop-phase facts that say
    /// something NEW survive as the delta.
    static func merged(start: [ContextFact], stop: [ContextFact]) -> CaptureContext? {
        var facts = start
        for fact in stop where !facts.contains(where: { $0.kind == fact.kind && $0.value == fact.value }) {
            facts.append(fact)
        }
        return facts.isEmpty ? nil : CaptureContext(facts: facts)
    }

    func first(_ kind: String) -> ContextFact? {
        facts.first { $0.kind == kind }
    }
}

extension CaptureRenderer {
    /// The paste-ready artifact for handing an utterance to an agent: a
    /// fixed framing line (a cold receiver can't otherwise know the quoted
    /// block is verbatim speech whose "this/here" resolve against the
    /// evidence), the words as a quote, then the evidence with provenance.
    /// Rendered on demand, never stored — the stored bundle stays raw so
    /// this format can improve without migrations.
    static func renderWithContext(_ capture: Capture) -> String {
        let framing = "Voice note with screen context — the quoted words are verbatim "
            + "speech; resolve \"this/here/these\" against the evidence below it."
        let quoted = render(capture)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        var lines = [framing, "", quoted]
        // Window titles often embed the app name already ("InfuseFlow —
        // homepage prototype - Google Chrome"); don't stutter.
        let windowPart = capture.windowTitle.isEmpty || capture.windowTitle.contains(capture.appName)
            ? capture.windowTitle
            : "\(capture.appName) · \(capture.windowTitle)"
        var provenance = ["— spoken in \(windowPart.isEmpty ? capture.appName : windowPart)"]
        var pointed: [String] = []
        let facts = capture.context?.facts ?? []
        for fact in facts {
            switch fact.kind {
            case "pageURL":
                provenance.append("— page: \(fact.value)")
            case "document":
                // Chrome reports AXDocument = the page URL; a duplicate line
                // is noise for the receiver.
                if !facts.contains(where: { $0.kind == "pageURL" && $0.value == fact.value }) {
                    provenance.append("— document: \(fact.value)")
                }
            case "selection":
                provenance.append("— selected text: \"\(fact.value)\"")
            case "pointedElement":
                let role = fact.detail.map { " (\($0))" } ?? ""
                pointed.append("\(fact.value)\(role)")
            default:
                provenance.append("— \(fact.kind): \(fact.value)")
            }
        }
        // Pointing is a gesture: the sweep renders in order, so "this whole
        // section" arrives as the section's rows, not one frozen word.
        if pointed.count == 1 {
            provenance.append("— pointed at: \(pointed[0])")
        } else if pointed.count > 1 {
            provenance.append("— pointed at while speaking, in order:")
            provenance.append(contentsOf: pointed.map { "    • \($0)" })
        }
        lines.append("")
        lines.append(contentsOf: provenance)
        return lines.joined(separator: "\n")
    }
}
