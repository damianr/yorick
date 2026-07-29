import Foundation

/// The mode in which a capture was recorded.
enum CaptureMode: String, Codable, Sendable {
    case dictation   // User was in a text field — text was typed at cursor
    case contextual  // User was pointing at UI — capture stored for later use
}

/// Lifecycle state of a capture.
enum CaptureState: String, Codable, Sendable {
    case new       // Just captured, not yet viewed
    case active    // User has expanded or interacted with it
    case done      // User marked it done or exported it
}

/// What kind of thought a capture represents. Kinds are DISPOSITIONS — what
/// should happen to the artifact — and a kind earns existence only with a
/// distinct EXIT. There are exactly two ways a noted capture leaves:
/// handed off (action) or read (note). Yorick is not a lifecycle app —
/// whether a handed-off action ever gets *done* is another system's business.
enum CaptureKind: String, Codable, Sendable, CaseIterable {
    case action     // needs taking care of — exits by handoff
    case note       // worth keeping — exits by being read
    case dictation  // pure transcription — already delivered at the cursor

    /// Decode a stored raw value, collapsing retired taxonomies so old
    /// records keep loading: the 2026 genres (question/idea/journal → note)
    /// and the July 2026 review/todo split (→ action).
    static func fromStored(_ raw: String?) -> CaptureKind? {
        guard let raw else { return nil }
        if let kind = CaptureKind(rawValue: raw) { return kind }
        switch raw {
        case "review", "todo": return .action
        case "question", "idea", "journal": return .note
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .action: return "Action"
        case .note: return "Note"
        case .dictation: return "Dictation"
        }
    }
}

/// A project attribution with a confidence score from the classifier.
struct ProjectTag: Codable, Sendable, Hashable {
    let name: String
    let confidence: Double
}

/// An action applied to an utterance after transcription. Effects are only
/// appended, never replaced — the history is the audit/undo trail that lets
/// "do the other thing" flip the latest disposition at any time.
struct CaptureEffect: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case inserted  // pasted at the cursor
        case copied    // left on the clipboard (insert fallback)
        case noted     // filed in the stream as an observation
    }

    let kind: Kind
    /// Insertion target (app name) when known.
    let target: String?
    let timestamp: Date
}

/// Structured response from Claude for a single capture.
struct ProcessedCapture: Codable, Sendable {
    let kind: CaptureKind
    let title: String
    let content: String
    let projectTags: [ProjectTag]
    let actionHint: String?
}

/// Audio health stats computed from the recorded WAV before transcription.
/// These make it possible to separate model errors from microphone/path errors.
struct AudioDiagnostics: Codable, Sendable {
    let sampleRate: Int
    let channelCount: Int
    let bitDepth: Int
    let durationSeconds: Double
    let peakDBFS: Double?
    let overallRMSDBFS: Double?
    let activeSpeechRMSDBFS: Double?
    let noiseFloorDBFS: Double?
    let percentile90RMSDBFS: Double?
    let clippedSampleCount: Int
    let clippedSamplePercent: Double
    let dcOffsetPercent: Double
    let activeFramePercent: Double
    let nearSilentFramePercent: Double
    let zeroCrossingsPerSecond: Double
    let signalToNoiseDB: Double?
    let notes: [String]
    let retainedAudioFileName: String?

    var summary: String {
        [
            "Format: \(sampleRate) Hz, \(channelCount) channel(s), \(bitDepth)-bit",
            "Duration: \(String(format: "%.2f", durationSeconds))s",
            "Peak: \(Self.formatDB(peakDBFS)), RMS: \(Self.formatDB(overallRMSDBFS)), active RMS: \(Self.formatDB(activeSpeechRMSDBFS))",
            "Noise floor: \(Self.formatDB(noiseFloorDBFS)), p90 RMS: \(Self.formatDB(percentile90RMSDBFS)), SNR: \(Self.formatNumber(signalToNoiseDB)) dB",
            "Clipping: \(clippedSampleCount) (\(String(format: "%.4f", clippedSamplePercent))%), DC offset: \(String(format: "%.3f", dcOffsetPercent))% FS",
            "Active frames: \(String(format: "%.1f", activeFramePercent))%, near-silent frames: \(String(format: "%.1f", nearSilentFramePercent))%, zero crossings: \(String(format: "%.0f", zeroCrossingsPerSecond))/s",
            "Retained WAV: \(retainedAudioFileName ?? "(off)")",
            "Notes: \(notes.isEmpty ? "(none)" : notes.joined(separator: " "))"
        ].joined(separator: "\n")
    }

    private static func formatDB(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-inf dBFS" }
        return String(format: "%.1f dBFS", value)
    }

    private static func formatNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-inf" }
        return String(format: "%.1f", value)
    }
}

/// Debug record for understanding why a contextual capture became the note it did.
/// This is intentionally stored with each capture so reliability issues can be
/// diagnosed from real examples instead of memory.
struct CaptureDiagnostics: Codable, Sendable {
    let modeDecision: String
    let rawAppName: String
    let identifiedAppName: String
    let windowTitle: String
    let audioFileSizeBytes: Int
    let cursorSampleCount: Int
    let contextSnapshotCount: Int
    let screenFrameCount: Int
    let selectedFrameCount: Int
    let candidateProjects: [String]
    let appliedTagSummary: String
    let classifierSummary: String?
    let screenCaptureStatus: String
    let audioDiagnostics: AudioDiagnostics?
    let microphoneDeviceUID: String?
    let microphoneDeviceName: String?
    let microphoneDeviceAvailable: Bool?
    let preferredMicrophoneMode: String?
    let activeMicrophoneMode: String?
    let cursorTimeline: String
    let contextEvidence: String

    var plainText: String {
        [
            "Mode: \(modeDecision)",
            "App: \(rawAppName) -> \(identifiedAppName)",
            "Window: \(windowTitle.isEmpty ? "(none)" : windowTitle)",
            "Microphone: \(microphoneDeviceName ?? "(system default)")\(microphoneDeviceAvailable == false ? " (selected device unavailable; using default)" : "")",
            "Microphone UID: \(microphoneDeviceUID ?? "(default)")",
            "Microphone mode: preferred \(preferredMicrophoneMode ?? "(unknown)"), active \(activeMicrophoneMode ?? "(unknown)")",
            "Audio bytes: \(audioFileSizeBytes)",
            "",
            "Audio Diagnostics",
            audioDiagnostics?.summary ?? "(not available)",
            "",
            "Cursor samples: \(cursorSampleCount)",
            "Context snapshots: \(contextSnapshotCount)",
            "Screen frames: \(screenFrameCount), selected for model: \(selectedFrameCount)",
            "Screen capture: \(screenCaptureStatus)",
            "Candidate projects: \(candidateProjects.isEmpty ? "(none)" : candidateProjects.joined(separator: ", "))",
            "Tags: \(appliedTagSummary.isEmpty ? "(none)" : appliedTagSummary)",
            "Classifier: \(classifierSummary ?? "(not run)")",
            "",
            "Context Evidence",
            contextEvidence.isEmpty ? "(none)" : contextEvidence,
            "",
            "Cursor Timeline",
            cursorTimeline.isEmpty ? "(none)" : cursorTimeline
        ].joined(separator: "\n")
    }
}

/// A single recording session — the universal primitive in Yorick.
struct Capture: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let mode: CaptureMode
    /// Where it was recorded (frontmost app at record time). Semantically distinct from `appliedTags`.
    let appName: String
    let windowTitle: String
    let transcript: String
    /// Legacy processed markdown — kept for rendering old captures. New captures prefer `content`.
    let processedInstructions: String?
    let transcriptSegments: [TranscriptSegment]
    let durationSeconds: Int
    let screenshotFileNames: [String]
    var state: CaptureState
    /// When the capture was marked done. Drives the done-fade prune — done
    /// items exit the stream for good after a grace window.
    var doneAt: Date?

    // MARK: - Universal capture fields

    let kind: CaptureKind
    /// Short (~40 char) scannable summary from the classifier.
    let title: String?
    /// Cleaned body from the classifier. Falls back to `processedInstructions` / `transcript`.
    let content: String?
    /// Project attributions with confidence ≥ 0.85 (auto-applied).
    var appliedTags: [String]
    /// Project attributions with 0.5 ≤ confidence < 0.85 (one-click accept/dismiss).
    var suggestedTags: [ProjectTag]
    /// Optional hint from classifier, e.g. "ui-change", "follow-up", "answer-me".
    let actionHint: String?
    /// What happened to this utterance (inserted/copied/noted), in order.
    /// NOTE: copy-constructor call sites must pass this through explicitly —
    /// the default exists only for fresh captures.
    var effects: [CaptureEffect]
    /// True when transcription failed and the WAV was retained — the row
    /// offers Retry. Long recordings are never silently dropped.
    var needsTranscription: Bool
    /// Evidence/debug payload for auditing context inference.
    let diagnostics: CaptureDiagnostics?

    init(
        id: UUID,
        timestamp: Date,
        mode: CaptureMode,
        appName: String,
        windowTitle: String,
        transcript: String,
        processedInstructions: String? = nil,
        transcriptSegments: [TranscriptSegment] = [],
        durationSeconds: Int,
        screenshotFileNames: [String] = [],
        state: CaptureState,
        doneAt: Date? = nil,
        kind: CaptureKind = .note,
        title: String? = nil,
        content: String? = nil,
        appliedTags: [String] = [],
        suggestedTags: [ProjectTag] = [],
        actionHint: String? = nil,
        effects: [CaptureEffect] = [],
        needsTranscription: Bool = false,
        diagnostics: CaptureDiagnostics? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.mode = mode
        self.appName = appName
        self.windowTitle = windowTitle
        self.transcript = transcript
        self.processedInstructions = processedInstructions
        self.transcriptSegments = transcriptSegments
        self.durationSeconds = durationSeconds
        self.screenshotFileNames = screenshotFileNames
        self.state = state
        self.doneAt = doneAt
        self.kind = kind
        self.title = title
        self.content = content
        self.appliedTags = appliedTags
        self.suggestedTags = suggestedTags
        self.actionHint = actionHint
        self.effects = effects
        self.needsTranscription = needsTranscription
        self.diagnostics = diagnostics
    }

    // MARK: - Codable (backward-compatible decode)

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, mode, appName, windowTitle, transcript
        case processedInstructions, transcriptSegments, durationSeconds
        case screenshotFileNames, state, doneAt
        case kind, title, content, appliedTags, suggestedTags, actionHint
        case effects, needsTranscription
        case diagnostics
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.mode = try c.decode(CaptureMode.self, forKey: .mode)
        self.appName = try c.decode(String.self, forKey: .appName)
        self.windowTitle = try c.decode(String.self, forKey: .windowTitle)
        self.transcript = try c.decode(String.self, forKey: .transcript)
        self.processedInstructions = try c.decodeIfPresent(String.self, forKey: .processedInstructions)
        self.transcriptSegments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .transcriptSegments) ?? []
        self.durationSeconds = try c.decode(Int.self, forKey: .durationSeconds)
        self.screenshotFileNames = try c.decodeIfPresent([String].self, forKey: .screenshotFileNames) ?? []
        // Records from before `state` existed (April 2026) must stay decodable —
        // a required key here silently strands them on disk forever.
        self.state = try c.decodeIfPresent(CaptureState.self, forKey: .state) ?? .new
        self.doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)

        // New fields with migrations for records written before universal capture.
        // Decode kind as a raw string: retired genres map to .note and an
        // unrecognized value (future vocabulary change) must degrade gracefully,
        // not throw and drop the whole record.
        let kindRaw = try c.decodeIfPresent(String.self, forKey: .kind)
        self.kind = CaptureKind.fromStored(kindRaw)
            ?? (self.mode == .dictation ? .dictation : .note)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.content = try c.decodeIfPresent(String.self, forKey: .content)
        // Legacy captures: migrate appName → appliedTags so project sidebar still works
        if let applied = try c.decodeIfPresent([String].self, forKey: .appliedTags) {
            self.appliedTags = applied
        } else {
            let legacyApp = try c.decode(String.self, forKey: .appName)
            self.appliedTags = legacyApp.isEmpty ? [] : [legacyApp]
        }
        self.suggestedTags = try c.decodeIfPresent([ProjectTag].self, forKey: .suggestedTags) ?? []
        self.actionHint = try c.decodeIfPresent(String.self, forKey: .actionHint)
        // Records written before effects existed: derive the implied disposition
        // from the mode so the flip key works on old captures too.
        if let effects = try c.decodeIfPresent([CaptureEffect].self, forKey: .effects) {
            self.effects = effects
        } else {
            let impliedKind: CaptureEffect.Kind = self.mode == .dictation ? .inserted : .noted
            self.effects = [CaptureEffect(
                kind: impliedKind,
                target: self.mode == .dictation ? self.appName : nil,
                timestamp: self.timestamp
            )]
        }
        self.needsTranscription = try c.decodeIfPresent(Bool.self, forKey: .needsTranscription) ?? false
        self.diagnostics = try c.decodeIfPresent(CaptureDiagnostics.self, forKey: .diagnostics)
    }

    // MARK: - Derived

    /// The best available text — structured content, then processed, then raw transcript.
    var bestText: String {
        content ?? processedInstructions ?? transcript
    }

    /// "App · Window" without stuttering — window titles often embed the
    /// app name already ("InfuseFlow — homepage prototype - Google Chrome").
    /// The one source line used by the HUD card header and exports alike.
    var sourceLine: String {
        if windowTitle.isEmpty { return appName }
        if windowTitle.contains(appName) { return windowTitle }
        return "\(appName) · \(windowTitle)"
    }

    /// First ~150 chars for preview display.
    var transcriptPreview: String {
        let trimmed = bestText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 150 { return trimmed }
        return String(trimmed.prefix(150)) + "…"
    }

    /// Relative time description.
    var relativeTime: String {
        let interval = Date().timeIntervalSince(timestamp)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    /// Whether this is a browser-based capture (for favicon display).
    var isBrowser: Bool {
        let browsers: Set<String> = ["Google Chrome", "Safari", "Firefox", "Arc", "Brave Browser", "Microsoft Edge", "Opera"]
        return browsers.contains(appName) ||
               !appName.contains(".") && appName != windowTitle && windowTitle.contains(appName)
    }

}

/// A group of captures from the same review session.
struct CaptureSession: Identifiable {
    let id: String  // appName + date bucket
    let appName: String
    let captures: [Capture]
    let startTime: Date

    var relativeTime: String {
        let interval = Date().timeIntervalSince(startTime)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    var totalDuration: Int {
        captures.reduce(0) { $0 + $1.durationSeconds }
    }

    var newCount: Int {
        captures.filter { $0.state == .new }.count
    }

    /// All items as a numbered list for copy.
    /// Flattens any items that are already numbered lists to avoid "1. 1." double numbering.
    var numberedList: String {
        var allItems: [String] = []
        for capture in captures {
            let text = capture.bestText.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            if lines.count > 1 && lines.first?.range(of: #"^\d+\."#, options: .regularExpression) != nil {
                for line in lines {
                    allItems.append(line.replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression))
                }
            } else {
                allItems.append(text.replacingOccurrences(of: #"^\d+\.\s*"#, with: "", options: .regularExpression))
            }
        }

        return allItems.enumerated().map { (i, item) in
            "\(i + 1). \(item)"
        }.joined(separator: "\n")
    }
}
