import Foundation

/// Yorick's ENTIRE analytics surface — client and contract in one file. No
/// SDK: usage is one HTTPS POST to Yorick's own endpoint, whose ~70-line
/// source is public in the site repo (api/ping.js on heyyorick.com).
/// TELEMETRY.md at the repo root mirrors this file for people who read docs
/// before source. If a diff touches telemetry anywhere else in the codebase,
/// something is wrong.
///
/// The shape is COUNTS, not an event stream: counted events increment a
/// per-day counter here, and a debounced flush posts the day's cumulative
/// totals — install id, local day, counts, app version. Cumulative payloads
/// with a last-wins write upstream mean lost or repeated sends self-heal;
/// there is no queue to maintain and no delivery to guarantee.
///
/// The rules, in order:
///
/// - No content, ever. No transcripts, no audio, no window titles, no names
///   of apps dictated into. The payload is fixed keys with integer values —
///   there is deliberately no path here that sends free-form text.
/// - Anonymous by design. The install id is a random UUID minted on this
///   Mac at first send, derived from nothing and linkable to nothing. The
///   endpoint never stores where a request came from.
/// - One off switch, checked here. The Settings toggle ("Share anonymous
///   usage counts") gates everything — call sites never need to know it
///   exists.
enum Telemetry {
    /// Settings toggle key. Default ON: the payload is counts, never content,
    /// the switch is one click away in Settings, and onboarding says so in
    /// plain words — the same posture as Sparkle's update check.
    static let shareUsageCountsKey = "shareUsageCounts"

    /// Yorick's own collector. Empty this string to build a telemetry-free
    /// Yorick — nothing is counted or sent without it.
    private static let endpoint = "https://heyyorick.com/api/ping"

    private static let installIDKey = "telemetryInstallID"
    private static let stateKey = "telemetryDayCounts"
    private static let lastFlushKey = "telemetryLastFlush"

    /// Every event call sites can report. Counted cases increment a payload
    /// field; the others are accepted (so call sites stay uniform) and
    /// deliberately not sent — see the switch in `send`.
    enum Event: String {
        case launched
        case dictationTyped
        case catchSaved
        case captureCopied
        case cleanupToggled
        case onboardingStep
        case onboardingCompleted
        case panelOpened
    }

    static var isEnabled: Bool {
        !endpoint.isEmpty && UserDefaults.standard.bool(forKey: shareUsageCountsKey)
    }

    /// Called once at launch; registers the toggle's default.
    static func start() {
        UserDefaults.standard.register(defaults: [shareUsageCountsKey: true])
    }

    /// The only path out. `parameters` is accepted for call-site stability
    /// and ignored — a counts payload has no event metadata.
    static func send(_ event: Event, _ parameters: [String: String] = [:]) {
        guard isEnabled else { return }
        let field: String?
        switch event {
        case .launched: field = "launches"
        case .dictationTyped: field = "dictations"
        case .catchSaved: field = "catches"
        case .captureCopied: field = "copies"
        case .panelOpened: field = "panels"
        case .cleanupToggled, .onboardingStep, .onboardingCompleted: field = nil
        }
        guard let field else { return }

        let defaults = UserDefaults.standard
        var state = (defaults.dictionary(forKey: stateKey)) ?? [:]
        let day = localDay()
        if (state["day"] as? String) != day {
            // Day rolled over: post yesterday's final tally before resetting,
            // so a day's tail isn't silently dropped.
            if state["day"] != nil { post(state) }
            state = ["day": day]
        }
        state[field] = ((state[field] as? Int) ?? 0) + 1
        defaults.set(state, forKey: stateKey)

        // Launch always flushes (it's the "still alive" beat); otherwise a
        // 30s debounce keeps a burst of dictations to a couple of requests.
        let now = Date().timeIntervalSince1970
        if event == .launched || now - defaults.double(forKey: lastFlushKey) > 30 {
            defaults.set(now, forKey: lastFlushKey)
            post(state)
        }
    }

    /// The user's LOCAL calendar day — "used 47 times yesterday" should mean
    /// the user's yesterday, not UTC's.
    private static func localDay() -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static var installID: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: installIDKey) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: installIDKey)
        return id
    }

    /// Fire and forget. A failed send is corrected by the next one — the
    /// payload is the day's running total, not a delta.
    private static func post(_ state: [String: Any]) {
        guard let day = state["day"] as? String, let url = URL(string: endpoint) else { return }
        let body: [String: Any] = [
            "id": installID,
            "day": day,
            "dictations": state["dictations"] as? Int ?? 0,
            "catches": state["catches"] as? Int ?? 0,
            "launches": state["launches"] as? Int ?? 0,
            "copies": state["copies"] as? Int ?? 0,
            "panels": state["panels"] as? Int ?? 0,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request).resume()
    }
}
