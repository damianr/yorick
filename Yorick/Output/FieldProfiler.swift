import Foundation

/// What kind of field is about to receive the paste. Derived from AX signals
/// via a conservative allowlist — an uncertain signal is `.standard`, which
/// means "today's behavior exactly". Detection here shapes formatting only;
/// it never gates whether the paste happens (routing owns that).
enum FieldProfile: String, Sendable {
    /// A search box: a trailing period breaks exact-match search, and a
    /// trailing space can trip as-you-type suggestions.
    case search
    /// An email-address input: spoken-form normalization matters most here,
    /// and trailing punctuation/space invalidates the value.
    case emailAddress
    /// A URL input: same containment as email.
    case url
    /// A password field: never transform, insert exactly what was spoken.
    case secure
    /// Everything else, including "no idea": current behavior.
    case standard
}

/// The handful of strings FieldProfiler reads. Kept as plain values so the
/// profiler is a pure function — AccessibilityCapture fills it from the
/// focused element; tests fill it from fixtures.
struct FieldShapingSignals: Sendable {
    var role = ""
    var subrole = ""
    var roleDescription = ""
    var placeholder = ""
    var identifier = ""
    var label = ""
}

enum FieldProfiler {
    /// Unambiguous AX signals first (subroles are ground truth when present),
    /// then hint words in the human-facing strings. Order matters: Safari's
    /// unified field says "Search or enter website name" — search wins, and
    /// its shaping (strip terminal period, no trailing space) is right for an
    /// address bar too.
    static func profile(_ signals: FieldShapingSignals) -> FieldProfile {
        if signals.subrole == "AXSecureTextField" { return .secure }
        if signals.subrole == "AXSearchField" { return .search }

        let hints = [signals.roleDescription, signals.placeholder, signals.identifier, signals.label]
            .map { $0.lowercased() }
        if hints.contains(where: { $0.contains("search") }) { return .search }
        if hints.contains(where: { $0.contains("email") || $0.contains("e-mail") }) { return .emailAddress }
        if hints.contains(where: { $0.contains("url") || $0.contains("website") || $0.contains("web address") }) {
            return .url
        }
        return .standard
    }
}

/// The text that actually goes out, per profile. Total pure function: no
/// throws, no model, no I/O; every branch degrades to identity-plus-space
/// (the shipped behavior) rather than inventing.
struct ShapedInsertion: Sendable, Equatable {
    let text: String
    /// Dictation historically appends one space so consecutive utterances
    /// read naturally. Search/email/URL fields want the bare value.
    let appendsTrailingSpace: Bool

    var outbound: String { appendsTrailingSpace ? text + " " : text }
}

enum TranscriptShaper {
    static func shape(normalized: String, raw: String, profile: FieldProfile) -> ShapedInsertion {
        switch profile {
        case .secure:
            // Exactly what was spoken — normalization could corrupt a
            // dictated passphrase, and a trailing space certainly would.
            return ShapedInsertion(text: raw, appendsTrailingSpace: false)
        case .search, .emailAddress, .url:
            return ShapedInsertion(text: strippingTerminalPeriod(normalized), appendsTrailingSpace: false)
        case .standard:
            return ShapedInsertion(text: normalized, appendsTrailingSpace: true)
        }
    }

    /// Removes exactly one sentence-terminal period — the transcription
    /// engine's full stop, not the user's. An ellipsis ("wait...") is kept:
    /// a doubled period before the end means the dot was content.
    private static func strippingTerminalPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix("..") else { return trimmed }
        return String(trimmed.dropLast())
    }
}
