import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Can the on-device model tell one thought from several?
///
/// Splitting a rambling capture into multiple tickets is the feature this
/// question gates, and it decomposes into two halves with very different
/// difficulty. DETECTION — "is this one task or three?" — is a small bounded
/// count. SEGMENTATION — "where exactly do they divide?" — is boundary
/// placement on speech, which has no clean edges. This eval measures the
/// first, because if detection can't hold there is nothing to segment, and
/// because a wrong count is the error a user would notice immediately.
///
/// Nothing is built on this yet. It exists to answer the question with a
/// number instead of a guess, before any of it ships.
///
///   TEST_RUNNER_YORICK_EVAL=1 xcodebuild … \
///     -only-testing:YorickTests/SplitDetectionEval
final class SplitDetectionEval: XCTestCase {

    private struct Case {
        let name: String
        let transcript: String
        /// How many separate, independently-actionable tasks are in here.
        let expected: Int
        /// True when the utterance carries an explicit discourse marker
        /// ("also", "another thing"). Those are findable with a regex, so
        /// scoring them separately shows how much the model is actually
        /// adding over a deterministic pre-pass.
        let hasMarker: Bool

        init(_ name: String, _ transcript: String, expected: Int, marker: Bool) {
            self.name = name
            self.transcript = transcript
            self.expected = expected
            self.hasMarker = marker
        }
    }

    private static let cases: [Case] = [
        // --- Single thoughts that RAMBLE. The trap: length reads as plurality.
        .init("one thought, long and winding",
              "so the export button is broken, it throws when the list is empty, "
              + "I think because we never guard the count before we map over it, "
              + "and it's been like that since we moved to the new store",
              expected: 1, marker: false),

        .init("one thought with a self-correction",
              "the pill shows up at the bottom, no wait, it shows up at the bottom "
              + "only when the field is a search field, that's the case that's wrong",
              expected: 1, marker: false),

        .init("one thought listing symptoms",
              "onboarding is rough, the permission step doesn't explain itself, "
              + "the buttons are tiny and the whole thing feels cramped",
              expected: 1, marker: false),

        // --- Genuinely multiple, with explicit markers.
        .init("two tasks, explicit marker",
              "the pricing page still says beta and we should take that down. "
              + "Also, the footer links to the old repo",
              expected: 2, marker: true),

        .init("three tasks, explicit markers",
              "first thing, the export throws on an empty list. "
              + "Another thing is the onboarding copy is too long. "
              + "And separately I want to look at why the pill flickers in Terminal",
              expected: 3, marker: true),

        .init("two tasks, oh-and marker",
              "we need to fix the empty state on the saved list, "
              + "oh and the settings gear is misaligned by a pixel",
              expected: 2, marker: true),

        // --- Genuinely multiple, NO marker. The hard case.
        .init("two tasks, no marker",
              "the download button needs to be more prominent on mobile. "
              + "The changelog page hasn't been updated since March",
              expected: 2, marker: false),

        .init("two tasks, no marker, same surface",
              "the hero copy is too long. The CTA should sit above the fold",
              expected: 2, marker: false),

        // --- Adversarial: markers that DON'T signal a new task.
        .init("marker inside one thought",
              "the button is too small and also the wrong color, "
              + "it needs to be bigger and warmer",
              expected: 1, marker: true),

        .init("enumeration inside one thought",
              "there are three places this breaks, the list, the card and the "
              + "settings row, all from the same missing guard",
              expected: 1, marker: true),
    ]

    private static let instructions = """
        You count separate, independently-actionable tasks in a spoken note.

        A task is separate only if it could be worked on by a different person \
        on a different day without reference to the others. Symptoms of one \
        problem are ONE task. A list of places a single bug shows up is ONE \
        task. A self-correction is ONE task. Words like "also" and "another \
        thing" often signal a new task but not always — judge the content, \
        not the connective.

        Reply with the count.
        """

    func testSplitDetection() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["YORICK_EVAL"] == "1",
            "Eval is opt-in: set YORICK_EVAL=1"
        )
        try XCTSkipUnless(IssueComposer.isAvailable, "On-device model unavailable on this Mac")

        let passes = 3
        var hits = 0, total = 0
        var markerHits = 0, markerTotal = 0
        var unmarkedHits = 0, unmarkedTotal = 0
        var overSplit = 0, underSplit = 0

        print("\n=== Split detection — \(Self.cases.count) cases × \(passes) passes ===\n")

        for testCase in Self.cases {
            var counts: [Int] = []
            for _ in 0..<passes {
                let answer = await Self.count(testCase.transcript)
                counts.append(answer ?? -1)
                total += 1
                if testCase.hasMarker { markerTotal += 1 } else { unmarkedTotal += 1 }
                if answer == testCase.expected {
                    hits += 1
                    if testCase.hasMarker { markerHits += 1 } else { unmarkedHits += 1 }
                } else if let answer {
                    // Direction matters more than the rate. Over-splitting
                    // shows the user tickets to merge; under-splitting
                    // silently buries the second task inside the first.
                    if answer > testCase.expected { overSplit += 1 } else { underSplit += 1 }
                }
            }
            let caseHits = counts.filter { $0 == testCase.expected }.count
            let mark = caseHits == passes ? "✓" : (caseHits == 0 ? "✗" : "~")
            print("""
                \(mark) \(caseHits)/\(passes)  \(testCase.name)\(testCase.hasMarker ? "  [marker]" : "")
                    wanted \(testCase.expected), got \(counts.map(String.init).joined(separator: ", "))
                """)
        }

        func pct(_ n: Int, _ d: Int) -> String {
            d == 0 ? "—" : "\(Int((Double(n) / Double(d) * 100).rounded()))%"
        }
        print("""

            === Overall \(hits)/\(total) (\(pct(hits, total)))
                with a discourse marker:  \(markerHits)/\(markerTotal) (\(pct(markerHits, markerTotal)))
                without one:              \(unmarkedHits)/\(unmarkedTotal) (\(pct(unmarkedHits, unmarkedTotal)))
                over-split \(overSplit) · under-split \(underSplit) ===

            """)
    }

    private static func count(_ transcript: String) async -> Int? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                return try await session.respond(
                    to: transcript, generating: TaskCount.self
                ).content.count
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct TaskCount {
    @Guide(description: "How many separate, independently-actionable tasks are in the note. Usually 1. Just the number.")
    var count: Int
}
#endif
