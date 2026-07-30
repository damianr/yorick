import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import KeyboardShortcuts
import os

// MARK: - State

enum SessionState: Equatable {
    case idle
    case recording
    case transcribing
    case error(String)
}

/// A short-lived, self-dismissing HUD message. Warnings report drops and
/// fallbacks; receipts report — in past tense — what just happened to an
/// utterance, so a glance answers "did it do the right thing" without the
/// user having to predict the mode up front.
struct TransientNotice: Equatable, Identifiable {
    enum Style: Equatable {
        case warning
        case receipt
    }

    let id = UUID()
    let message: String
    var style: Style = .warning
    /// Secondary line, e.g. the flip-key hint on receipts.
    var detail: String? = nil
    /// Sticky notices stay until clicked — used for failures the user must
    /// see (a 3-second flash after a minutes-long transcription is a miss).
    var sticky: Bool = false
}

/// Where the pill sits relative to its anchor, driving both window origin
/// and how the pill aligns inside the fixed-size transparent window.
/// Anchored placements are LEADING-aligned — the pill sits at the field's
/// top-left, right where the text goes in.
enum HUDPillPlacement: String, Sendable {
    case bottomCenter  // no anchor: observation flow, fallbacks
    case aboveField    // preferred: pill bottom-leading, grows upward
    case belowField    // fallback near screen top: pill top-leading, grows down
}

extension Notification.Name {
    /// Posted by SessionManager when the HUD window should move. userInfo
    /// carries "origin" as NSValue(point:) — absent means bottom-center.
    static let hudReposition = Notification.Name("hudReposition")
}

// MARK: - Session Manager

@MainActor
@Observable
final class SessionManager {
    var state: SessionState = .idle
    var audioLevel: Float = 0
    var captureMode: CaptureMode = .contextual
    var lastSavedCapture: Capture?  // For toast display
    var transientNotice: TransientNotice?  // For dropped-capture HUD notice
    /// True while the opt-in pre-insert cleanup pass is running — the pill
    /// says "Cleaning up…" so the wait between release and landing is
    /// announced, never a silent stall.
    var cleanupRunning = false
    /// Where the pill sits relative to its anchor (see HUDPillPlacement).
    var hudPillPlacement: HUDPillPlacement = .bottomCenter
    let captureStore = CaptureStore()

    /// The field the HUD is anchored to — frame, AX element identity, and
    /// owning pid; nil means bottom-center. Identity is what makes the pill
    /// feel attached: when this exact element stops being focused (window or
    /// tab switch), the pill leaves with it.
    private var hudAnchor: AccessibilityCapture.FieldTarget?

    private(set) var startedAt: Date?
    private(set) var appName: String?
    private(set) var windowTitle: String?

    let microphoneManager = MicrophoneManager()
    private let audioCapture = AudioCapture()
    /// Guards the async start resolution against superseding sessions.
    private var startResolveGeneration = 0
    /// The dictation fast path anchored this session — the full resolution
    /// may refine confidence and diagnostics but never demotes the mode:
    /// immediate field evidence wins, period.
    private var startFastPathHit = false
    /// False for the first ≤80ms of a session while the fast probe races
    /// the clock — the pill waits imperceptibly and then appears at the
    /// RIGHT place, instead of flashing at top before flying to a field.
    var hudReady = true
    /// True when the pill is seated at a field's leading edge rather than a
    /// readable caret (single-line exception) — the pill must render as a
    /// capsule there: the pointer corner claims an exact insertion point.
    var hudAnchorApproximate = false
    private var audioFileURL: URL?
    private var startTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    /// Bumped each time processing starts (or is cancelled) so a stale, unwinding
    /// processing task can't mutate shared state belonging to a newer session.
    private var processingGeneration = 0
    private var recordingTimer: Timer?
    private var elapsedSeconds: Int = 0
    private var silentSeconds: Int = 0
    private var modeDecisionSummary = ""
    /// Trigger-time evidence quality: .low lets the transcript pick the
    /// disposition after transcription instead of the cursor heuristic.
    private var startConfidence: AccessibilityCapture.EditabilityDecision.Confidence = .high
    private var modeWasForced = false
    /// True while the recording pill should say "Listening" instead of
    /// committing to a mode the router may overrule at disposition time.
    var modeIsTentative: Bool {
        startConfidence == .low && !modeWasForced
    }
    /// The most recently saved utterance — target of the flip key. Falls back
    /// to the newest capture in the store, so there is no expiry window.
    private var lastUtteranceID: UUID?
    var showSilenceWarning = false

    var formattedDuration: String {
        let mins = elapsedSeconds / 60
        let secs = elapsedSeconds % 60
        return String(format: "%d:%02d", mins, secs)
    }

    /// Start capture — SHOW FIRST, DECIDE SECOND. The pill must appear at
    /// hotkey speed, but the editability ladder is synchronous AX IPC into
    /// an arbitrary app — cold apps took visible fractions of a second,
    /// which read as the app not listening. The session starts provisional
    /// (contextual, unanchored, audio already rolling) and the resolved
    /// decision lands the pill at the field a beat later. A wrong-for-a-beat
    /// placement costs nothing: routing re-decides at stop, and every
    /// transcript persists regardless.
    func startIfIdle(forcedMode: CaptureMode? = nil) {
        // A stuck error state must never soft-lock the hotkey.
        if case .error = state { state = .idle }
        guard state == .idle else { return }

        modeWasForced = forcedMode != nil
        captureMode = forcedMode ?? .contextual
        startConfidence = .low
        modeDecisionSummary = "mode=\(captureMode.rawValue), forced=\(modeWasForced), resolving"
        startCapture()

        // Pre-insert cleanup pays its model load NOW, while the user is
        // talking — by release the session is warm and the pass costs only
        // generation.
        if UserDefaults.standard.bool(forKey: Self.cleanupDictationKey) {
            LocalIntelligence.prewarmCleanup()
        }

        // DICTATION LEADS. Before the pill's first paint, a fast field
        // probe (direct role match, no heuristics) races an 80ms clock:
        // unambiguous field evidence puts the pill AT the field from its
        // very first frame, mode already dictation — no top-flash, no
        // flight. Anything else shows the unanchored pill within ~5 frames
        // and lets the full resolution decide.
        hudReady = false
        startFastPathHit = false
        let fastTask = Task.detached(priority: .userInitiated) {
            AccessibilityCapture.fastFieldProbe()
        }
        Task { @MainActor [weak self] in
            let fast: AccessibilityCapture.FieldTarget? = await withTaskGroup(
                of: AccessibilityCapture.FieldTarget?.self
            ) { group in
                group.addTask { await fastTask.value }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let self, self.state == .recording else { self?.hudReady = true; return }
            if let fast, forcedMode == nil {
                self.startFastPathHit = true
                self.captureMode = .dictation
                self.modeDecisionSummary += ", fastPath=field"
                self.setHUDAnchor(fast)
            } else {
                self.setHUDAnchor(nil)
            }
            self.hudReady = true
        }
        resolveStartDecision(forcedMode: forcedMode)
    }

    /// Runs the corroborated editability decision off the main thread and
    /// applies it: mode, confidence, diagnostics, and — when the evidence
    /// says "typing" — the pill's flight from unanchored to the field. The
    /// pill anchors where routing intends to type, never on bare focus (web
    /// and Electron apps keep some field focused at all times). If the
    /// decision lands unanchored, the retry loop keeps watching for
    /// late-settling focus for the rest of the recording.
    private func resolveStartDecision(forcedMode: CaptureMode?) {
        startResolveGeneration += 1
        let generation = startResolveGeneration
        Task { @MainActor [weak self] in
            let decision = await Task.detached(priority: .userInitiated) {
                AccessibilityCapture.editabilityDecisionAtCursor()
            }.value
            let target: AccessibilityCapture.FieldTarget? = decision.isEditable
                ? await Task.detached(priority: .userInitiated) {
                    AccessibilityCapture.focusedEditableFieldTarget()
                }.value
                : nil
            guard let self, self.startResolveGeneration == generation,
                  self.state == .recording else { return }
            if forcedMode == nil, !self.startFastPathHit {
                self.captureMode = decision.isEditable ? .dictation : .contextual
            }
            self.startConfidence = self.startFastPathHit ? .high : decision.confidence
            self.modeDecisionSummary = "mode=\(self.captureMode.rawValue), forced=\(self.modeWasForced), accessibilityTrusted=\(AXIsProcessTrusted()), \(decision.summary)"
            if let ctx = decision.cursorContext {
                self.modeDecisionSummary += ", cursorElement=\(ctx.role):\(ctx.title ?? ctx.label ?? "untitled") in \(ctx.appName)"
            }
            print("[Session] Mode resolved: \(self.captureMode.rawValue) (\(self.modeDecisionSummary))")
            // Never unanchor a fast-path pill — immediate field evidence won.
            if self.startFastPathHit { return }
            if decision.isEditable, let target {
                self.setHUDAnchor(target)
            } else if self.hudAnchor == nil {
                self.acquireFieldAnchorWithRetry()
            }
        }
    }

    /// Poll for a focused editable field for as long as the recording runs,
    /// anchoring the pill the moment focus resolves. Independent of capture mode:
    /// the routing decision happens at stop, but the pill should follow focus
    /// throughout. Self-cancelling: bails the moment an anchor lands or the
    /// session ends.
    private func acquireFieldAnchorWithRetry() {
        Task { @MainActor in
            for _ in 0..<50 { // ~5s cap at 100ms; recording usually ends first
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                guard state == .recording, hudAnchor == nil else { return }
                // Same corroborated decision as everywhere else — a focused
                // field only anchors once the evidence says "typing," so a
                // deliberate point-away keeps the pill honestly unanchored.
                // Off-main: each tick is AX IPC that must not hitch the pill.
                let resolved = await Task.detached(priority: .utility) {
                    () -> AccessibilityCapture.FieldTarget? in
                    AccessibilityCapture.editabilityDecisionAtCursor().isEditable
                        ? AccessibilityCapture.focusedEditableFieldTarget()
                        : nil
                }.value
                guard state == .recording, hudAnchor == nil else { return }
                if let target = resolved {
                    setHUDAnchor(target)
                    return
                }
            }
        }
    }

    /// Stop capture — transcribes and either types text or saves capture.
    func stopIfRecording() {
        guard case .recording = state else { return }
        stopCapture()
    }

    /// Cancel an in-flight transcription/processing pass (the user tapping the
    /// cancel control on the transcribing pill). Nothing is inserted or saved.
    func cancelProcessing() {
        guard state == .transcribing else { return }
        processingTask?.cancel()
        processingTask = nil
        // Invalidate the running task's generation so its unwind can't reset
        // state or save anything for a session the user already abandoned.
        processingGeneration &+= 1
        state = .idle
        cleanupRunning = false
        print("[Session] Transcription cancelled by user")
    }

    /// Surface a self-dismissing HUD notice for a dropped capture. Guarded by
    /// generation so a stale pass can't flash a notice over a newer session.
    private func presentNotice(_ rejection: TranscriptQuality.Rejection, generation: Int) {
        guard generation == processingGeneration else { return }
        print("[Session] Dropped capture: \(rejection.logReason)")
        transientNotice = TransientNotice(message: rejection.userMessage)
    }


    // MARK: - HUD placement (field-adjacent pill)

    /// Must match HUDWindow's contentRect — the window never resizes, the
    /// transparent panel just gets repositioned and the pill re-aligned inside.
    private static let hudWindowSize = NSSize(width: 500, height: 300)
    /// Vertical clearance the pill needs on the chosen side of the caret.
    private static let hudPillClearance: CGFloat = 84
    /// Small lift of the pill off the caret midline so it doesn't crowd the text.
    private static let hudCaretGap: CGFloat = 8

    /// Anchor the HUD to a field or reset to bottom-center. The pill sits at
    /// the field's TOP-LEFT — right where the text goes in — and falls below
    /// only when there's no room above. The position IS the mode indicator:
    /// field-adjacent = dictation, bottom-center = observation.
    private func setHUDAnchor(_ target: AccessibilityCapture.FieldTarget?) {
        hudAnchor = target
        anchorMissTicks = 0
        // Reset on EVERY placement — a stale true from a previous anchor
        // must never survive into a new one; only the single-line tier
        // below re-asserts it.
        hudAnchorApproximate = false
        guard let target else {
            stopAnchorTracking()
            hudPillPlacement = .bottomCenter
            NotificationCenter.default.post(name: .hudReposition, object: nil)
            return
        }
        startAnchorTracking()

        // Placement tiers: the pill sits at the CARET when the app exposes it.
        // When it doesn't, ONE narrow exception before honest bottom-center:
        // a single-line field with a sane frame (Chrome's omnibox — measured:
        // its Views toolkit answers every bounds-for-range query with a
        // degenerate 0×0 rect) seats the pill at the field's leading edge —
        // and the pill renders as a CAPSULE there, never the pointer corner,
        // so it claims "typing into this field" without claiming the exact
        // spot. Multi-line editors get no such middle tier: near-but-off the
        // cursor reads as broken, and bottom-center makes no false claim.
        let exactCaret = target.caret
        // Single-line by AX CONTRACT (role), not by pixel height — a compact
        // multi-line composer must never get the leading-edge tier. Height
        // stays only as a sanity clamp against mis-reported frames.
        let singleLineRoles: Set<String> = ["AXTextField", "AXSearchField"]
        let roleEdge: CGRect? = singleLineRoles.contains(target.role)
            && target.frame.height <= 44 && target.frame.width > 0
            ? CGRect(x: target.frame.minX + 4, y: target.frame.minY, width: 0, height: target.frame.height)
            : nil
        // A live SELECTION opens the leading-edge tier at ANY height — the
        // GENERALIZED answer to per-app selection-geometry quirks (Chromium
        // answers every range query with a degenerate rect; ChatGPT's
        // composer exposes even less). The selection highlight already marks
        // the exact landing spot on screen, so the pill only needs to claim
        // the right field — seated at its top-leading corner, as a capsule,
        // never the pointer corner. Exact selection-start geometry still
        // wins wherever the app provides it (native fields, Mail).
        let selectionEdge: CGRect? = target.hasSelection && target.frame.width > 0
            ? CGRect(x: target.frame.minX + 4, y: target.frame.minY, width: 0, height: min(target.frame.height, 24))
            : nil
        let singleLineEdge = roleEdge ?? selectionEdge
        guard let caret = exactCaret ?? singleLineEdge else {
            Self.placementLog.info("no caret → bottom-center (frame=\(NSStringFromRect(target.frame), privacy: .public))")
            hudPillPlacement = .bottomCenter
            NotificationCenter.default.post(name: .hudReposition, object: nil)
            return
        }
        hudAnchorApproximate = (exactCaret == nil)
        if hudAnchorApproximate {
            Self.placementLog.info("no caret, single-line field → leading-edge capsule (frame=\(NSStringFromRect(target.frame), privacy: .public))")
        }

        // AX coordinates are global top-left; Cocoa windows are bottom-left,
        // flipped against the PRIMARY screen (same convention as axCursorPoint).
        let frame = caret
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let field = NSRect(
            x: frame.minX,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(field) }) ?? NSScreen.main else {
            hudPillPlacement = .bottomCenter
            NotificationCenter.default.post(name: .hudReposition, object: nil)
            return
        }
        let visible = screen.visibleFrame
        let size = Self.hudWindowSize

        // Pill left edge lines up with the field's left edge (leading-aligned
        // content sits at the window's left, inset by the content padding —
        // the padding exists so the glow can fade without clipping).
        var x = field.minX - HUDPlacement.contentPadding
        x = min(max(x, visible.minX), visible.maxX - size.width)

        // The pill hovers just ABOVE the caret line (8px off its midline) —
        // tried directly on the caret and it covered the landing text; tried
        // fully above the line and it floated into toolbars. This is the tuned
        // middle. Falls below the caret only when there's no room above.
        // The window origin compensates for the glow padding: the PILL's
        // visual offset from the caret is unchanged (it was tuned when the
        // content padding was 8pt — hence the +8/−8 terms).
        let caretMidY = field.midY
        let fitsAbove = caretMidY + Self.hudPillClearance <= visible.maxY
        let fitsBelow = caretMidY - Self.hudPillClearance >= visible.minY
        let origin: NSPoint
        if fitsAbove {
            hudPillPlacement = .aboveField
            origin = NSPoint(
                x: x,
                y: caretMidY + Self.hudCaretGap + 8 - HUDPlacement.contentPadding
            )
        } else if fitsBelow {
            hudPillPlacement = .belowField
            origin = NSPoint(
                x: x,
                y: caretMidY - size.height - Self.hudCaretGap - 8 + HUDPlacement.contentPadding
            )
        } else {
            hudPillPlacement = .bottomCenter
            NotificationCenter.default.post(name: .hudReposition, object: nil)
            return
        }
        Self.placementLog.info("""
            caret placement: caretAX=\(NSStringFromRect(caret), privacy: .public) \
            fieldAX=\(NSStringFromRect(target.frame), privacy: .public) \
            flippedField=\(NSStringFromRect(field), privacy: .public) \
            visible=\(NSStringFromRect(visible), privacy: .public) \
            placement=\(self.hudPillPlacement.rawValue, privacy: .public) \
            origin=\(NSStringFromPoint(origin), privacy: .public)
            """)
        NotificationCenter.default.post(
            name: .hudReposition,
            object: nil,
            userInfo: ["origin": NSValue(point: origin)]
        )
    }

    // MARK: - Anchor tracking (follow a growing field)

    /// While the pill is anchored, follow the field: autogrowing composers
    /// (Claude's input grows upward as text lands) invalidate any one-shot
    /// position, leaving the pill covering the words it just inserted. 4 Hz
    /// corrects the post-paste jump within a frame or two of it happening,
    /// and also covers scrolling and window drags.
    private var anchorTrackTimer: Timer?

    private func startAnchorTracking() {
        guard anchorTrackTimer == nil else { return }
        // .common run-loop mode, same as the recording timer — a default-mode
        // timer stops ticking during menu tracking and drags.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.anchorTrackTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        anchorTrackTimer = timer
    }

    private func stopAnchorTracking() {
        anchorTrackTimer?.invalidate()
        anchorTrackTimer = nil
    }

    /// Consecutive ticks where no editable field had focus — one tick of
    /// grace absorbs transient AX read failures before the pill reacts.
    private var anchorMissTicks = 0
    /// Consecutive ticks with no pill content visible — lets the exit animation
    /// finish in place before the window goes home.
    private var pillGoneTicks = 0

    private func anchorTrackTick() {
        guard let anchor = hudAnchor else {
            stopAnchorTracking()
            return
        }
        // The pill disappeared without an explicit dismiss (dictation finished,
        // a notice faded) — send the window home and stop polling. But WAIT for
        // the exit animation (~0.3s) first: repositioning the window while the
        // pill is mid-fade flashed a ghost of it at the new spot.
        let pillVisible = state == .recording || state == .transcribing
            || transientNotice != nil
        guard pillVisible else {
            pillGoneTicks += 1
            if pillGoneTicks >= 2 { // ≥500ms at 4 Hz — fade is long done
                setHUDAnchor(nil)
            }
            return
        }
        pillGoneTicks = 0

        let current = AccessibilityCapture.focusedEditableFieldTarget()

        // Recording/transcribing: the pill previews wherever the dictation
        // would land NOW, so it follows focus freely — and goes home when no
        // field is focused (insertion at stop re-anchors as needed). A transient
        // AX read failure must NOT send the pill home: keep the last good anchor
        // and only relocate to bottom-center after sustained loss (~1s), which
        // reads as a deliberate move rather than a flicker.
        if let current {
            anchorMissTicks = 0
            followAnchorGeometry(current)
        } else {
            anchorMissTicks += 1
            if anchorMissTicks >= 4 { setHUDAnchor(nil) }
        }
    }

    /// Reposition only on real movement — AX geometry jitters by a pixel —
    /// but always refresh the stored identity.
    private func followAnchorGeometry(_ target: AccessibilityCapture.FieldTarget) {
        // Placement tracks the CARET only. Reposition when it moves, appears
        // (bottom-center → caret once the assistive tree unlocks), or disappears
        // (caret → bottom-center). When neither old nor new has a caret, there's
        // nothing to follow — just refresh the tracked identity.
        let oldCaret = hudAnchor?.caret
        let newCaret = target.caret
        switch (oldCaret, newCaret) {
        case (nil, nil):
            // No caret either side — but the FIELD may have moved (window
            // drag, composer reflow); keep the tracked identity fresh.
            let old = hudAnchor?.frame ?? .zero
            let f = target.frame
            if abs(f.minX - old.minX) > 1 || abs(f.minY - old.minY) > 1 ||
               abs(f.width - old.width) > 1 || abs(f.height - old.height) > 1 {
                setHUDAnchor(target)
            } else {
                hudAnchor = target
            }
        case let (old?, new?):
            if abs(new.minX - old.minX) > 1 || abs(new.minY - old.minY) > 1 ||
               abs(new.width - old.width) > 1 || abs(new.height - old.height) > 1 {
                setHUDAnchor(target)
            } else {
                hudAnchor = target
            }
        default:
            // Caret appeared or disappeared — re-place.
            setHUDAnchor(target)
        }
    }

    // MARK: - Pre-insert cleanup

    /// HUD placement diagnostics: `log show --process Yorick --info | grep placement`.
    private static let placementLog = Logger(subsystem: "com.heyyorick.Yorick", category: "placement")

    /// Opt-in: run the on-device disfluency pass BETWEEN transcription and
    /// the paste, so the field only ever shows final text. This replaced the
    /// post-insert receipt (skull-in-the-gutter offering Cleanup): while
    /// that pass ran, the raw text sat in the field with no strong
    /// in-progress tell, and a Return during the window sent the message —
    /// then the finished cleanup pasted into the emptied composer. The
    /// focus check couldn't catch it (chat apps keep the same field focused
    /// after send). Editing a live field is a read-modify-write against the
    /// user; editing before the paste has no such race. Off by default.
    static let cleanupDictationKey = "cleanupDictation"

    /// Cleanup raced against a wall clock, same shape as every other bound
    /// in this file: the model gets `capSeconds` and then the raw words
    /// win. Any failure — timeout, guardrail refusal, empty result — means
    /// nil, and the caller inserts what was said.
    private static func boundedCleanup(_ text: String, capSeconds: Double) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await LocalIntelligence.cleanupTranscript(text)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(capSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Recording

    private func startCapture() {
        elapsedSeconds = 0
        startedAt = Date()
        transientNotice = nil
        state = .recording

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            appName = frontApp.localizedName
            windowTitle = Self.windowTitle(for: frontApp.processIdentifier)
            print("[Session] Start: app=\(appName ?? "nil") windowTitle=\(windowTitle ?? "nil")")
        }

        silentSeconds = 0
        showSilenceWarning = false
        // .common run-loop mode: a default-mode timer stops ticking while a menu
        // is open or during drags — exactly when the user is pointing at things.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsedSeconds += 1
                if self.audioLevel < 0.001 {
                    self.silentSeconds += 1
                } else {
                    self.silentSeconds = 0
                    self.showSilenceWarning = false
                }
                self.showSilenceWarning = self.silentSeconds >= 10
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer

        audioCapture.onLevelUpdate = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }

        startTask = Task {
            let deviceUID = microphoneManager.effectiveDeviceUID

            // Start audio capture
            do {
                let url = try await audioCapture.start(preferredDeviceUID: deviceUID)
                // The user may have tapped the hotkey faster than the mic
                // session spun up — don't leave an orphaned session running
                // (and a temp file) for a recording that already stopped.
                guard state == .recording, !Task.isCancelled else {
                    _ = audioCapture.stop()
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                audioFileURL = url
            } catch {
                // Recover to idle with a visible notice — a lingering .error
                // state used to dead-lock the hotkey until app relaunch.
                recordingTimer?.invalidate()
                recordingTimer = nil
                if state == .recording {
                    state = .idle
                    transientNotice = TransientNotice(message: "Microphone unavailable: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    private func stopCapture() {
        let mode = captureMode

        startTask?.cancel()
        startTask = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        audioLevel = 0
        audioCapture.onLevelUpdate = nil

        let audioURL = audioCapture.stop()
        state = .transcribing

        processingGeneration &+= 1
        let generation = processingGeneration
        let wasForced = modeWasForced
        let confidence = startConfidence
        processingTask = Task {
            await self.processCapture(
                audioURL: audioURL,
                sessionAppName: appName ?? "Unknown",
                sessionWindowTitle: windowTitle ?? "",
                sessionStartedAt: startedAt!,
                duration: elapsedSeconds,
                mode: mode,
                modeWasForced: wasForced,
                startConfidence: confidence,
                generation: generation
            )
        }
    }

    private func processCapture(
        audioURL: URL?,
        sessionAppName: String,
        sessionWindowTitle: String,
        sessionStartedAt: Date,
        duration: Int,
        mode: CaptureMode,
        modeWasForced: Bool,
        startConfidence: AccessibilityCapture.EditabilityDecision.Confidence,
        generation: Int
    ) async {
        // Only the generation that still owns the session may reset state. A
        // cancelled or superseded pass unwinds without disturbing a newer one.
        defer {
            if generation == processingGeneration {
                state = .idle
                processingTask = nil
            }
        }

        // True while this pass is still the active, un-cancelled one. Gates every
        // user-visible side effect (insert/save/notice) so an abandoned pass stays
        // silent.
        func isLive() -> Bool { generation == processingGeneration && !Task.isCancelled }

        guard let audioURL else {
            print("[Session] No audio file")
            return
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
        guard fileSize > 1000 else {
            print("[Session] Audio too small (\(fileSize) bytes), skipping")
            presentNotice(.noAudio, generation: generation)
            return
        }

        let retainedAudioFileName = AudioDebugSettings.keepAudio ? AudioDebugSettings.retainedAudioFileName : nil
        let audioDiagnostics: AudioDiagnostics?
        do {
            // Off the main actor — scanning a long recording's samples was a
            // visible UI hitch while the "Transcribing" pill was showing.
            audioDiagnostics = try await Task.detached(priority: .userInitiated) {
                try AudioDiagnosticsAnalyzer.analyzeWAV(
                    at: audioURL,
                    retainedAudioFileName: retainedAudioFileName
                )
            }.value
            print("[Session] Audio diagnostics:\n\(audioDiagnostics?.summary ?? "(none)")")
        } catch {
            audioDiagnostics = nil
            print("[Session] Audio diagnostics unavailable: \(error.localizedDescription)")
        }

        // Silence gate: if the audio levels show no usable speech, don't even
        // transcribe — Whisper would hallucinate caption boilerplate from silence.
        if let rejection = TranscriptQuality.silenceRejection(audioDiagnostics) {
            presentNotice(rejection, generation: generation)
            return
        }

        guard isLive() else { return }

        do {
            // 1. Transcribe locally via Whisper
            let result = try await TranscriptionService.transcribe(audioURL: audioURL)
            let spoken = result.transcript
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Spoken-form normalization ("damian at gmail dot com" → an
            // address) corrects transcription artifacts, so it applies to
            // every utterance — typed and saved alike. `spoken` survives for
            // the one field kind that must get the words untouched (secure).
            let cleaned = SpokenFormNormalizer.normalize(spoken)
            if cleaned != spoken {
                print("[Session] Spoken-form normalization rewrote an address run")
            }

            guard isLive() else { return }

            // Hallucination gate: reject empty results and known Whisper caption
            // artifacts ("Thanks for watching", looped phrases) so we never insert
            // or save confident nonsense. BUT: the gates were tuned on short
            // clips, and a long ramble legitimately repeats phrases — a false
            // positive here would cost minutes of speech. Long recordings are
            // therefore saved (flagged, never inserted) instead of dropped.
            if let rejection = TranscriptQuality.contentRejection(transcript: cleaned, diagnostics: audioDiagnostics) {
                if duration >= Constants.neverDropDurationSeconds, !cleaned.isEmpty {
                    saveFlaggedCapture(
                        transcript: cleaned,
                        reason: rejection.logReason,
                        audioURL: audioURL,
                        sessionAppName: sessionAppName,
                        sessionWindowTitle: sessionWindowTitle,
                        sessionStartedAt: sessionStartedAt,
                        duration: duration
                    )
                } else {
                    presentNotice(rejection, generation: generation)
                }
                return
            }

            print("[Session] Transcribed (\(mode.rawValue)): \(cleaned.prefix(100))...")

            // 2. Route the utterance. Forced and high-confidence starts keep
            // their mode; for the ambiguous grey zone (an editor was focused
            // but the pointer disagreed) the words themselves — plus where
            // keyboard focus is NOW — pick the disposition. The recording was
            // identical either way, so this choice costs nothing to flip later.
            // The stop check uses the SAME corroborated decision as the
            // start: bare "any editor focused" promoted observations to
            // dictations in every web/Electron app (they keep a field
            // focused at all times), trampling start-time evidence that the
            // pointer was deliberately elsewhere. Symmetry restores the
            // grey-zone contract: only corroborated typing intent inserts,
            // and a misread costs one Copy click, never a swallowed paste.
            let stopDecision = AXIsProcessTrusted() ? AccessibilityCapture.editabilityDecisionAtCursor() : nil
            let focusedEditableNow = stopDecision?.isEditable ?? false
            if let stopDecision {
                modeDecisionSummary += ", stopDecision=[\(stopDecision.summary)]"
            }
            let effectiveMode: CaptureMode
            if modeWasForced || startConfidence == .high {
                // A note-register opener is the one signal strong enough to
                // override an unforced dictation: "note to self…" spoken into
                // a focused field is still a note.
                if !modeWasForced, mode == .dictation,
                   let prefix = UtteranceRouter.leadingNotePrefix(in: cleaned) {
                    effectiveMode = .contextual
                    modeDecisionSummary += ", routed=contextual (register: starts with \"\(prefix)\")"
                } else {
                    effectiveMode = mode
                }
            } else {
                let routed = UtteranceRouter.route(
                    transcript: cleaned,
                    modeAtStart: mode,
                    focusedEditableAtStop: focusedEditableNow
                )
                effectiveMode = routed.disposition == .insert ? .dictation : .contextual
                modeDecisionSummary += ", routed=\(effectiveMode.rawValue) (\(routed.reason))"
                if effectiveMode != mode {
                    print("[Session] Routed \(mode.rawValue) → \(effectiveMode.rawValue): \(routed.reason)")
                }
            }

            // 3. For dictation: type text at cursor immediately — but re-verify
            // the target first. Focus may have moved (or AX may be denied) since
            // recording started; blind-pasting sprays text into the wrong app,
            // and an untrusted ⌘V silently drops the transcript entirely.
            let captureID = UUID()
            var effects: [CaptureEffect] = []
            // A dictation that couldn't be typed (nothing was focused) is kept in
            // the list rather than typed — recorded so the capture is filed as a
            // note, not a phantom insertion.
            var dictationSavedUntyped = false
            if effectiveMode == .dictation {
                guard isLive() else { return }
                let targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
                // Stage-0 field shaping: the kind of field receiving the paste
                // decides FORMATTING only (search: no trailing period or
                // space; secure: exactly as spoken) — never whether the paste
                // happens. Uncertain signals shape as .standard, i.e. today's
                // behavior byte-for-byte.
                let fieldProfile = AccessibilityCapture.focusedFieldShapingSignals()
                    .map(FieldProfiler.profile) ?? .standard
                // Pre-insert cleanup (opt-in): the disfluency pass runs HERE,
                // before anything is pasted, so the field only ever shows
                // final text — no window where provisional words invite a
                // Return. Bounded by the wall clock; any miss inserts the
                // words as spoken, and the LIST always keeps the un-cleaned
                // transcript as the recovery path. Cleanup is for PROSE:
                // shaped fields (email/URL/search) receive exact content and
                // secure fields never touch the model — and tiny utterances
                // are skipped outright, both because there's nothing to
                // clean and because near-empty inputs are where guided
                // generation misbehaves (an address dictated into Mail's To
                // field came back with the response schema appended,
                // field-reported).
                var polished = cleaned
                if fieldProfile == .standard,
                   cleaned.split(separator: " ").count >= 4,
                   UserDefaults.standard.bool(forKey: Self.cleanupDictationKey),
                   LocalIntelligence.isCleanupAvailable {
                    cleanupRunning = true
                    if let result = await Self.boundedCleanup(cleaned, capSeconds: 2.5) {
                        polished = result
                        if polished != cleaned {
                            print("[Session] Pre-insert cleanup edited the transcript")
                        }
                    } else {
                        print("[Session] Pre-insert cleanup missed its window — raw words inserted")
                    }
                    cleanupRunning = false
                    guard isLive() else { return }
                }
                let shaped = TranscriptShaper.shape(normalized: polished, raw: spoken, profile: fieldProfile)
                if fieldProfile != .standard {
                    print("[Session] Field profile=\(fieldProfile.rawValue) shaped the insertion")
                }
                if focusedEditableNow {
                    // Focus may have moved since record start — re-anchor the
                    // pill to the field actually receiving the paste.
                    setHUDAnchor(AccessibilityCapture.focusedEditableFieldTarget() ?? hudAnchor)
                    Self.insertTextAtCursor(shaped.outbound)
                    effects.append(CaptureEffect(kind: .inserted, target: targetApp, timestamp: Date()))
                    print("[Session] Text inserted at cursor")
                } else if AccessibilityCapture.hasAnyFocusedElement() {
                    // Detection couldn't confirm a field, but SOMETHING is focused
                    // — almost always a text field we failed to classify. Trust the
                    // dictation and paste; the transcript is saved to the list
                    // regardless, so a rare misfire costs nothing.
                    setHUDAnchor(nil)
                    Self.insertTextAtCursor(shaped.outbound)
                    effects.append(CaptureEffect(kind: .inserted, target: targetApp, timestamp: Date()))
                    print("[Session] Text pasted into unclassified focused element")
                } else {
                    // Nothing focused at all — genuine no-field. Keep it in the
                    // list, where every transcript already lives one Copy click away.
                    effects.append(CaptureEffect(kind: .noted, target: nil, timestamp: Date()))
                    dictationSavedUntyped = true
                    setHUDAnchor(nil)
                    transientNotice = TransientNotice(message: "No field focused — saved to your list")
                    print("[Session] No focus anywhere; dictation saved to list")
                }
            } else {
                effects.append(CaptureEffect(kind: .noted, target: nil, timestamp: Date()))
                // Observations report bottom-center — position differentiates
                // the two flows at a glance.
                setHUDAnchor(nil)
            }

            // 4. Name where it was spoken (browser tabs resolve to sites).
            let identified = AppIdentifier.identify(appName: sessionAppName, windowTitle: sessionWindowTitle)
            let primaryApp = identified.name

            let effectiveKind: CaptureKind = (effectiveMode == .dictation && !dictationSavedUntyped) ? .dictation : .note
            let microphoneDeviceUID = microphoneManager.effectiveDeviceUID
            let microphoneDeviceName = microphoneManager.selectedDeviceName
                ?? (microphoneDeviceUID == nil ? "System Default" : nil)
            let microphoneDeviceAvailable = microphoneManager.isSelectedDeviceAvailable
            let microphoneModes = Self.currentMicrophoneModes()
            let diagnostics = CaptureDiagnostics(
                modeDecision: modeDecisionSummary.isEmpty ? "mode=\(mode.rawValue)" : modeDecisionSummary,
                rawAppName: sessionAppName,
                identifiedAppName: primaryApp,
                windowTitle: sessionWindowTitle,
                audioFileSizeBytes: fileSize,
                cursorSampleCount: 0,
                contextSnapshotCount: 0,
                screenFrameCount: 0,
                selectedFrameCount: 0,
                candidateProjects: [],
                appliedTagSummary: "",
                classifierSummary: nil,
                screenCaptureStatus: "removed",
                audioDiagnostics: audioDiagnostics,
                microphoneDeviceUID: microphoneDeviceUID,
                microphoneDeviceName: microphoneDeviceName,
                microphoneDeviceAvailable: microphoneDeviceAvailable,
                preferredMicrophoneMode: microphoneModes.preferred,
                activeMicrophoneMode: microphoneModes.active,
                cursorTimeline: "",
                contextEvidence: ""
            )

            // 5. Save. The capture is complete the moment transcription ends —
            //    there is no background intelligence to wait for.
            let capture = Capture(
                id: captureID,
                timestamp: sessionStartedAt,
                mode: effectiveMode,
                appName: primaryApp,
                windowTitle: sessionWindowTitle,
                transcript: cleaned,
                processedInstructions: nil,
                transcriptSegments: result.transcriptSegments,
                durationSeconds: duration,
                screenshotFileNames: [],
                state: .new,
                kind: effectiveKind,
                title: nil,
                content: nil,
                appliedTags: [],
                suggestedTags: [],
                actionHint: nil,
                effects: effects,
                diagnostics: diagnostics
            )

            guard isLive() else { return }

            try captureStore.save(
                capture,
                screenshots: [],
                debugAudioURL: retainedAudioFileName == nil ? nil : audioURL
            )
            lastUtteranceID = capture.id
            print("[Session] Saved \(effectiveMode.rawValue) capture: \(primaryApp), \(duration)s")

            if effectiveMode == .contextual {
                lastSavedCapture = capture
            }
        } catch {
            print("[Session] Failed: \(error)")
            guard !(error is CancellationError) else { return }
            // The user spoke for a while and got nothing — never fail silently,
            // and never delete the audio. A stub lands in the stream with the
            // WAV retained so Retry can recover every word later.
            saveTranscriptionFailureStub(
                error: error,
                audioURL: audioURL,
                sessionAppName: sessionAppName,
                sessionWindowTitle: sessionWindowTitle,
                sessionStartedAt: sessionStartedAt,
                duration: duration
            )
        }
    }

    /// A capture whose transcript was flagged by the quality gates but is too
    /// long to discard. Saved as a note, never inserted, audio retained.
    private func saveFlaggedCapture(
        transcript: String,
        reason: String,
        audioURL: URL,
        sessionAppName: String,
        sessionWindowTitle: String,
        sessionStartedAt: Date,
        duration: Int
    ) {
        let capture = Capture(
            id: UUID(),
            timestamp: sessionStartedAt,
            mode: .contextual,
            appName: sessionAppName,
            windowTitle: sessionWindowTitle,
            transcript: transcript,
            durationSeconds: duration,
            screenshotFileNames: [],
            state: .new,
            kind: .note,
            title: "Flagged transcript (\(reason)) — review",
            effects: [CaptureEffect(kind: .noted, target: nil, timestamp: Date())],
            needsTranscription: true
        )
        do {
            try captureStore.save(capture, screenshots: [], debugAudioURL: audioURL)
            lastUtteranceID = capture.id
            transientNotice = TransientNotice(
                message: "Transcript flagged as suspect — saved to your stream for review",
                sticky: true
            )
            print("[Session] Flagged long capture saved (\(reason))")
        } catch {
            print("[Session] Failed to save flagged capture: \(error)")
        }
    }

    /// Transcription failed outright. Save a stub with the WAV retained so the
    /// recording survives; the row offers Retry.
    private func saveTranscriptionFailureStub(
        error: Error,
        audioURL: URL,
        sessionAppName: String,
        sessionWindowTitle: String,
        sessionStartedAt: Date,
        duration: Int
    ) {
        let capture = Capture(
            id: UUID(),
            timestamp: sessionStartedAt,
            mode: .contextual,
            appName: sessionAppName,
            windowTitle: sessionWindowTitle,
            transcript: "",
            durationSeconds: duration,
            screenshotFileNames: [],
            state: .new,
            kind: .note,
            title: "Transcription failed — audio saved",
            effects: [],
            needsTranscription: true
        )
        do {
            try captureStore.save(capture, screenshots: [], debugAudioURL: audioURL)
            lastUtteranceID = capture.id
            transientNotice = TransientNotice(
                message: "Transcription failed — recording saved to your stream",
                detail: "Open Yorick and press Retry. (\(error.localizedDescription))",
                sticky: true
            )
            print("[Session] Failure stub saved with retained audio (\(duration)s)")
        } catch {
            print("[Session] Failed to save failure stub: \(error)")
        }
    }

    /// Re-run transcription for a capture whose WAV was retained after a
    /// failure. The result lands as a note (the insertion moment has passed —
    /// the flip key inserts it if that's what was wanted).
    func retryTranscription(_ captureID: UUID) {
        guard let capture = captureStore.captures.first(where: { $0.id == captureID }) else { return }
        let audioURL = captureStore.audioURL(for: capture)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            transientNotice = TransientNotice(message: "Audio no longer on disk — cannot retry")
            return
        }

        transientNotice = TransientNotice(message: "Retrying transcription…", style: .receipt)
        Task { [weak self] in
            do {
                let result = try await TranscriptionService.transcribe(audioURL: audioURL)
                let cleaned = result.transcript
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "  ", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self else { return }
                guard let current = self.captureStore.captures.first(where: { $0.id == captureID }) else { return }
                guard !cleaned.isEmpty else {
                    self.transientNotice = TransientNotice(message: "Retry produced no speech — audio kept")
                    return
                }
                let updated = Capture(
                    id: current.id, timestamp: current.timestamp, mode: current.mode,
                    appName: current.appName, windowTitle: current.windowTitle,
                    transcript: cleaned,
                    transcriptSegments: result.transcriptSegments,
                    durationSeconds: current.durationSeconds,
                    screenshotFileNames: current.screenshotFileNames,
                    state: .new, kind: current.kind,
                    title: nil, content: nil,
                    appliedTags: current.appliedTags,
                    suggestedTags: current.suggestedTags,
                    actionHint: current.actionHint,
                    effects: current.effects + [CaptureEffect(kind: .noted, target: nil, timestamp: Date())],
                    needsTranscription: false,
                    diagnostics: current.diagnostics
                )
                self.captureStore.update(updated)
                self.lastUtteranceID = updated.id
                self.transientNotice = TransientNotice(
                    message: "Transcribed — in your stream",
                    style: .receipt
                )
            } catch {
                self?.transientNotice = TransientNotice(
                    message: "Retry failed: \(error.localizedDescription)",
                    sticky: true
                )
            }
        }
    }

    // MARK: - Text Insertion

    /// Insert text at the current cursor position via clipboard + ⌘V — the
    /// clipboard mechanics (snapshot, token guard, early-flush triggers,
    /// restore) live in PasteboardLease.
    private static func insertTextAtCursor(_ text: String) {
        PasteboardLease.begin(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            PasteboardLease.postPasteKeystroke()
            PasteboardLease.scheduleRestore()
        }
    }

    // MARK: - Helpers

    private static func windowTitle(for pid: pid_t) -> String? {
        // kCGWindowName is redacted without Screen Recording permission —
        // fall back to the AX focused-window title so app identification and
        // project hints don't silently degrade.
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]]
        if let title = windowList?.first(where: { ($0[kCGWindowOwnerPID] as? pid_t) == pid })?[kCGWindowName as CFString] as? String,
           !title.isEmpty {
            return title
        }

        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue((window as! AXUIElement), kAXTitleAttribute as CFString, &titleRef) == .success else { return nil }
        return titleRef as? String
    }

    private static func currentMicrophoneModes() -> (preferred: String?, active: String?) {
        guard #available(macOS 12.0, *) else {
            return (nil, nil)
        }

        return (
            microphoneModeName(AVCaptureDevice.preferredMicrophoneMode),
            microphoneModeName(AVCaptureDevice.activeMicrophoneMode)
        )
    }

    @available(macOS 12.0, *)
    private static func microphoneModeName(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .standard:
            return "standard"
        case .wideSpectrum:
            return "wideSpectrum"
        case .voiceIsolation:
            return "voiceIsolation"
        @unknown default:
            return "unknown"
        }
    }
}

