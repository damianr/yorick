import XCTest

/// Table-driven fixtures for Stage-0 normalization. Grow this corpus from
/// real dictations — a false transformation is a bug, a missed one is not.
final class SpokenFormNormalizerTests: XCTestCase {

    func testEmailRuns() {
        assertAll([
            ("damian at gmail dot com", "damian@gmail.com"),
            ("Damian at Gmail dot com", "Damian@gmail.com"),
            ("email me at damian at gmail dot com, thanks", "email me at damian@gmail.com, thanks"),
            ("damian dot rebman at gmail dot com", "damian.rebman@gmail.com"),
            ("damian underscore rebman at yahoo dot co dot uk", "damian_rebman@yahoo.co.uk"),
            ("damian plus spam at gmail dot com", "damian+spam@gmail.com"),
            ("damian dash r at fastmail dot fm", "damian-r@fastmail.fm"),
            // SpeechAnalyzer sometimes writes the domain dot itself.
            ("damian at gmail.com", "damian@gmail.com"),
            ("send it to damian at heyyorick dot com.", "send it to damian@heyyorick.com."),
        ])
    }

    func testEmailNonMatches() {
        assertUnchanged([
            "we met at noon",
            "meet me at the office",
            "I'll be at seven",
            "look at that",
            "she pointed at him",
            // "at" as preposition before a site reference — the local-part
            // stopword guard; the web rule may still fix the domain, so only
            // the @ must not appear.
            "note to self buy milk",
            "the meeting at 3pm",
        ])
        // Preposition-not-address: the domain normalizes, the @ must not appear.
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("the article at nytimes dot com"),
            "the article at nytimes.com"
        )
    }

    func testWebAddressRuns() {
        assertAll([
            ("heyyorick dot com", "heyyorick.com"),
            ("go to heyyorick dot com slash download", "go to heyyorick.com/download"),
            ("www dot heyyorick dot com", "www.heyyorick.com"),
            ("check linear dot app today", "check linear.app today"),
            ("docs are at swift dot org slash documentation", "docs are at swift.org/documentation"),
        ])
    }

    func testWebNonMatches() {
        assertUnchanged([
            "the dot com era",
            "a dot com company",
            "connect the dots",
            "dot your i's",
            "polka dot dress",
            // Unknown TLD stays as spoken — the cheap, honest failure.
            "gmail dot whatever",
        ])
    }

    func testAlreadyWrittenFormsUntouched() {
        assertUnchanged([
            "damian@gmail.com is my address",
            "see heyyorick.com for details",
            "version 2 dot oh", // no TLD shape
        ])
    }

    func testSurroundingTextPreserved() {
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("My email is damian at gmail dot com and my site is heyyorick dot com."),
            "My email is damian@gmail.com and my site is heyyorick.com."
        )
        // Runs never span lines.
        XCTAssertEqual(
            SpokenFormNormalizer.normalize("first line dot\ncom second line"),
            "first line dot\ncom second line"
        )
    }

    // MARK: - Helpers

    private func assertAll(_ cases: [(input: String, expected: String)], file: StaticString = #filePath, line: UInt = #line) {
        for c in cases {
            XCTAssertEqual(SpokenFormNormalizer.normalize(c.input), c.expected, "input: \(c.input)", file: file, line: line)
        }
    }

    private func assertUnchanged(_ inputs: [String], file: StaticString = #filePath, line: UInt = #line) {
        for input in inputs {
            XCTAssertEqual(SpokenFormNormalizer.normalize(input), input, "should not change: \(input)", file: file, line: line)
        }
    }
}
