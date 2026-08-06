import Foundation
import TelemetryDeck

/// Yorick's ENTIRE analytics surface. Every signal the app can send is a case
/// in the enum below, with its full payload documented beside it, and
/// TELEMETRY.md at the repo root mirrors this file for people who read docs
/// before source. If a diff touches telemetry anywhere else in the codebase,
/// something is wrong.
///
/// The rules, in order:
///
/// - No content, ever. No transcripts, no audio, no window titles, no names
///   of apps dictated into. There is deliberately no API here that accepts
///   free-form text — payloads are fixed keys with enumerable values.
/// - Anonymous by design. Yorick passes TelemetryDeck no user identifier;
///   the SDK derives one and hashes it, so counts cannot be tied to a person
///   or joined across apps.
/// - One off switch, checked here. The Settings toggle ("Share anonymous
///   usage counts") gates every signal in `send` — call sites never need to
///   know it exists.
/// - Dark until configured. `appID` names the app, not the user (the same
///   class of value as the appcast URL), and while it is empty nothing is
///   initialized and nothing is sent — a source build ships no telemetry.
enum Telemetry {
    /// Settings toggle key. Default ON: the payload is counts, never content,
    /// the switch is one click away in Settings, and onboarding says so in
    /// plain words — the same posture as Sparkle's update check.
    static let shareUsageCountsKey = "shareUsageCounts"

    /// The public TelemetryDeck app identifier. Empty until the TelemetryDeck
    /// app exists; empty means telemetry never runs.
    private static let appID = ""

    /// Every signal Yorick can send. Adding a case is a product decision:
    /// document it in TELEMETRY.md in the same commit.
    enum Event: String {
        /// The app started.
        case launched = "App.launched"
        /// A dictation was typed into a field. Parameter `engine`: the
        /// configured transcription engine ("appleAnalyzer" | "apple" |
        /// "whisper").
        case dictationTyped = "Dictation.typed"
        /// Words spoken outside a field were saved to the list — the catch.
        case catchSaved = "Catch.saved"
        /// A saved item was copied out, from the list or the card.
        case captureCopied = "Capture.copied"
        /// The pre-insert Cleanup setting flipped. Parameter `enabled`:
        /// "true" | "false".
        case cleanupToggled = "Cleanup.toggled"
        /// An onboarding step appeared. Parameter `step`: "welcome" |
        /// "setup" | "tryIt" | "done". A funnel, not behavior.
        case onboardingStep = "Onboarding.stepReached"
        /// Onboarding finished and the app handed off to the menu bar.
        case onboardingCompleted = "Onboarding.completed"
        /// The menu bar panel was opened.
        case panelOpened = "Panel.opened"
    }

    static var isEnabled: Bool {
        !appID.isEmpty && UserDefaults.standard.bool(forKey: shareUsageCountsKey)
    }

    /// Called once at launch. Registers the toggle's default and initializes
    /// the SDK, which batches signals locally and retries when offline —
    /// airplane mode stays a supported configuration.
    static func start() {
        UserDefaults.standard.register(defaults: [shareUsageCountsKey: true])
        guard !appID.isEmpty else { return }
        TelemetryDeck.initialize(config: .init(appID: appID))
    }

    /// The only path out. Parameters must be the documented keys for the
    /// event — never content.
    static func send(_ event: Event, _ parameters: [String: String] = [:]) {
        guard isEnabled else { return }
        TelemetryDeck.signal(event.rawValue, parameters: parameters)
    }
}
