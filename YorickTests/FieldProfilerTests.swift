import XCTest

final class FieldProfilerTests: XCTestCase {

    func testSubrolesAreGroundTruth() {
        XCTAssertEqual(FieldProfiler.profile(.init(subrole: "AXSecureTextField")), .secure)
        XCTAssertEqual(FieldProfiler.profile(.init(subrole: "AXSearchField")), .search)
        // Secure wins even with a confusing label.
        XCTAssertEqual(
            FieldProfiler.profile(.init(subrole: "AXSecureTextField", label: "Search password")),
            .secure
        )
    }

    func testHintWords() {
        XCTAssertEqual(FieldProfiler.profile(.init(roleDescription: "search text field")), .search)
        XCTAssertEqual(FieldProfiler.profile(.init(placeholder: "Search or enter website name")), .search)
        XCTAssertEqual(FieldProfiler.profile(.init(placeholder: "Email address")), .emailAddress)
        XCTAssertEqual(FieldProfiler.profile(.init(label: "E-mail")), .emailAddress)
        XCTAssertEqual(FieldProfiler.profile(.init(placeholder: "Website URL")), .url)
        XCTAssertEqual(FieldProfiler.profile(.init(identifier: "url-input")), .url)
    }

    func testUncertaintyIsStandard() {
        XCTAssertEqual(FieldProfiler.profile(.init()), .standard)
        XCTAssertEqual(FieldProfiler.profile(.init(role: "AXTextArea", roleDescription: "text entry area")), .standard)
        // "address" alone is ambiguous (street address) and must NOT profile.
        XCTAssertEqual(FieldProfiler.profile(.init(placeholder: "Address line 1")), .standard)
    }

    func testShaping() {
        // Search: engine's full stop goes, user's ellipsis stays, no trailing space.
        XCTAssertEqual(
            TranscriptShaper.shape(normalized: "weather in tokyo.", raw: "weather in tokyo.", profile: .search),
            ShapedInsertion(text: "weather in tokyo", appendsTrailingSpace: false)
        )
        XCTAssertEqual(
            TranscriptShaper.shape(normalized: "wait...", raw: "wait...", profile: .search).text,
            "wait..."
        )
        // Email field: normalized form, bare value.
        XCTAssertEqual(
            TranscriptShaper.shape(normalized: "damian@gmail.com.", raw: "damian at gmail dot com.", profile: .emailAddress),
            ShapedInsertion(text: "damian@gmail.com", appendsTrailingSpace: false)
        )
        // Secure: exactly as spoken, no normalization, no space.
        XCTAssertEqual(
            TranscriptShaper.shape(normalized: "damian@gmail.com", raw: "damian at gmail dot com", profile: .secure),
            ShapedInsertion(text: "damian at gmail dot com", appendsTrailingSpace: false)
        )
        // Standard: today's behavior byte-for-byte.
        let standard = TranscriptShaper.shape(normalized: "hello world.", raw: "hello world.", profile: .standard)
        XCTAssertEqual(standard.outbound, "hello world. ")
    }
}
