import Foundation

/// One verbatim piece of evidence gathered around an utterance — what was
/// selected, what page was open, what the pointer touched. Facts, never
/// inferences: the value is exactly what accessibility reported (length-
/// capped), with provenance, so a later consumer resolves the reference
/// itself. Yorick never interprets.
///
/// Restored from `enrichment-exits-v2` (2026-07-31) with one change of
/// meaning: this bundle is now a TRANSMISSION payload as well as a local
/// record. The caps and the secure-field exclusions stopped being hygiene and
/// became the boundary of what can leave the Mac, so they are load-bearing —
/// and every fact here is shown on the card before anything is sent.
struct ContextFact: Codable, Sendable, Equatable {
    /// "selection" | "pageURL" | "document" | "pointedElement"
    let kind: String
    /// Verbatim value, capped at collection time.
    let value: String
    /// Where it came from (element role etc.) — provenance, shown on request.
    let detail: String?
    /// "start" (hotkey down), "stop" (release), or "timeline" (the pointer
    /// sweep). Pointing happens while talking, so both snapshots matter and
    /// the delta is itself evidence.
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

    /// Start and stop snapshots merged: start-phase facts win (freeze the
    /// semantic target at trigger), stop-phase facts that say something NEW
    /// survive as the delta.
    static func merged(start: [ContextFact], stop: [ContextFact], timeline: [ContextFact] = []) -> CaptureContext? {
        var facts = start
        for fact in stop + timeline
        where !facts.contains(where: { $0.kind == fact.kind && $0.value == fact.value }) {
            facts.append(fact)
        }
        return facts.isEmpty ? nil : CaptureContext(facts: facts)
    }

    /// A one-line count for the card's disclosure label ("context · 3").
    var factCount: Int { facts.count }
}
