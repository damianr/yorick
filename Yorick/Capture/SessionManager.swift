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

/// A just-completed insertion, shown as an actionable pill next to the field:
/// Cleanup re-inserts a disfluency-free version; Undo removes the paste.
struct InsertionReceipt: Identifiable, Equatable {
    let id = UUID()
    /// The async ⌘V paste lands ~50–200ms after the receipt appears — the
    /// text-still-present check must not run before the text has arrived.
    let createdAt = Date()
    let captureID: UUID
    /// Exactly what was inserted (transcript + trailing space).
    let insertedText: String
    /// App that received the paste — actions bail if focus has moved elsewhere.
    let targetApp: String?
    /// Flip-key hint line.
    let hint: String?
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
    /// Actionable pill after a dictation lands: Cleanup / Undo at the field.
    var insertionReceipt: InsertionReceipt?
    /// The receipt is attached to its field: hidden while the field isn't
    /// focused (blur, window/tab switch), shown again on refocus.
    var receiptHidden = false
    /// Hover is intent — the fade clock and deadline stand down while the
    /// pointer is on the receipt.
    private var receiptPillHovered = false
    var cleanupInProgress = false
    /// Absolute end of the receipt's life — survives hide/show cycles.
    private var receiptDeadline: Date?
    /// Snapshot of the field's content taken once the paste has landed. The
    /// receipt lives only while the field still matches it: any edit, delete,
    /// or Return-to-send makes Cleanup/Undo stale, so the receipt retires.
    private var receiptContentSignature: AccessibilityCapture.ContentSignature?
    /// The field's content signature from JUST BEFORE the paste. If the first
    /// readable signature after the grace window equals this (or is empty),
    /// Return already fired inside the grace window and the text is gone —
    /// that state must be dismissed, never adopted as the baseline.
    private var receiptPreInsertSignature: AccessibilityCapture.ContentSignature?
    /// Geometry fallback for fields exposing no content info: a send snaps an
    /// autogrown composer back toward its single-line height.
    private var receiptBaselineFieldHeight: CGFloat?
    /// The words as spoken, kept so auto-cleanup can be reverted.
    private(set) var rawTranscriptForRevert: String?
    /// Whether auto-cleanup actually changed the text — the receipt only has a
    /// reason to exist (and offer Revert) when it did.
    private(set) var cleanupApplied = false
    /// Caret position just after the paste, for content-blind fields (Mail's
    /// WebKit body): any later caret movement means the user typed or edited, so
    /// the receipt retires — ⌘Z/Cleanup no longer map cleanly to our insertion.
    private var receiptBaselineCaret: CGRect?
    /// Where the pill sits relative to its anchor (see HUDPillPlacement).
    var hudPillPlacement: HUDPillPlacement = .bottomCenter
    let captureStore = CaptureStore()

    /// The field the HUD is anchored to — frame, AX element identity, and
    /// owning pid; nil means bottom-center. Identity is what makes the pill
    /// feel attached: when this exact element stops being focused (window or
    /// tab switch), the pill leaves with it.
    private var hudAnchor: AccessibilityCapture.FieldTarget?
    private var receiptDismissTask: Task<Void, Never>?

    private(set) var startedAt: Date?
    private(set) var appName: String?
    private(set) var windowTitle: String?

    let microphoneManager = MicrophoneManager()
    private let audioCapture = AudioCapture()
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

    /// Start capture — infers mode from cursor context.
    /// If cursor is in a text field → dictation (will type transcript at cursor).
    /// Otherwise → contextual capture (stores in Yorick).
    func startIfIdle(forcedMode: CaptureMode? = nil) {
        // A stuck error state must never soft-lock the hotkey.
        if case .error = state { state = .idle }
        guard state == .idle else { return }

        // Detect mode from cursor context. This is a starting guess, not the
        // verdict — for low-confidence evidence the transcript itself routes
        // the utterance after transcription (UtteranceRouter).
        let decision = AccessibilityCapture.editabilityDecisionAtCursor()
        let isEditable = decision.isEditable
        captureMode = forcedMode ?? (isEditable ? .dictation : .contextual)
        startConfidence = decision.confidence
        modeWasForced = forcedMode != nil
        let axTrusted = AXIsProcessTrusted()
        if forcedMode != nil {
            modeDecisionSummary = "mode=\(captureMode.rawValue), forced=true, automaticEditable=\(isEditable), accessibilityTrusted=\(axTrusted), \(decision.summary)"
        } else {
            modeDecisionSummary = "mode=\(captureMode.rawValue), forced=false, accessibilityTrusted=\(axTrusted), \(decision.summary)"
        }
        print("[Session] Mode detected: \(captureMode.rawValue) (\(modeDecisionSummary))")
        if let ctx = decision.cursorContext {
            print("[Session] Cursor element: role=\(ctx.role) app=\(ctx.appName) title=\(ctx.title ?? "nil")")
            modeDecisionSummary += ", cursorElement=\(ctx.role):\(ctx.title ?? ctx.label ?? "untitled") in \(ctx.appName)"
        }
        // A new utterance supersedes any lingering receipt — and it must be
        // cleared BEFORE the anchor is chosen: setHUDAnchor routes to the
        // receipt's gutter dock while a receipt exists, which parked the
        // RECORDING pill at the field's left edge when dictations came
        // back-to-back.
        dismissInsertionReceipt(reason: "superseded by new utterance")

        // The pill anchors to a focused editable field whenever one exists, and
        // sits bottom-center only when none does — a field-adjacent pill means
        // "will type here," bottom-center means "will save." This is driven by
        // focus, NOT the start-mode guess: after switching into an app (Electron
        // especially) the guess is often .contextual on the first capture because
        // the cursor probe hasn't settled, yet a field IS focused — so gating on
        // the guess left the first pill stranded at bottom-center.
        setHUDAnchor(AccessibilityCapture.focusedEditableFieldTarget())
        startCapture()
        // Focus can lag the hotkey by well over a second (app still coming
        // forward, focus just moved in). If we didn't anchor, keep polling for
        // the whole recording so the pill lands on the field mid-utterance
        // instead of only on the next capture.
        if hudAnchor == nil {
            acquireFieldAnchorWithRetry()
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
                if let target = AccessibilityCapture.focusedEditableFieldTarget() {
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
        guard let target else {
            stopAnchorTracking()
            hudPillPlacement = .bottomCenter
            NotificationCenter.default.post(name: .hudReposition, object: nil)
            return
        }
        startAnchorTracking()

        // The receipt has its own placement rule: the gutter dock (left margin of
        // the field), which by construction never covers the inserted text and is
        // reflow-stable in bottom-anchored composers. Only once the skull is
        // actually on screen, though — while cleanup runs the transcribing pill is
        // showing and belongs at the caret like every other live pill.
        if insertionReceipt != nil, cleanupApplied, !cleanupInProgress {
            setReceiptGutterAnchor(target)
            return
        }

        // Two-tier placement: the pill sits at the CARET when the app exposes it,
        // otherwise honest bottom-center. There is no frame-anchored middle tier —
        // a pill near-but-off the cursor reads as broken (it claims to know where
        // you're typing and then misses), whereas bottom-center makes no such
        // claim. The field is still tracked (for receipt dismiss) either way.
        guard let caret = target.caret else {
            Self.placementLog.info("no caret → bottom-center (frame=\(NSStringFromRect(target.frame), privacy: .public))")
            hudPillPlacement = .bottomCenter
            NotificationCenter.default.post(name: .hudReposition, object: nil)
            return
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
        // content sits at the window's left, inset by the content padding).
        var x = field.minX - 6
        x = min(max(x, visible.minX), visible.maxX - size.width)

        // The pill hovers just ABOVE the caret line (8px off its midline) —
        // tried directly on the caret and it covered the landing text; tried
        // fully above the line and it floated into toolbars. This is the tuned
        // middle. Falls below the caret only when there's no room above.
        let caretMidY = field.midY
        let fitsAbove = caretMidY + Self.hudPillClearance <= visible.maxY
        let fitsBelow = caretMidY - Self.hudPillClearance >= visible.minY
        let origin: NSPoint
        if fitsAbove {
            hudPillPlacement = .aboveField
            origin = NSPoint(x: x, y: caretMidY + Self.hudCaretGap)
        } else if fitsBelow {
            hudPillPlacement = .belowField
            origin = NSPoint(x: x, y: caretMidY - size.height - Self.hudCaretGap)
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

    /// Diameter of the receipt's skull circle (HUDContentView.receiptPillHeight)
    /// and its clearance from the field's edge.
    private static let receiptSkullSize: CGFloat = 30
    private static let receiptGutterGap: CGFloat = 6

    /// The receipt's gutter dock: the skull sits in the margin just OUTSIDE the
    /// field's left edge — marginalia, like a Docs comment or an editor gutter.
    /// Vertically it rides the caret line when the app exposes one; otherwise it
    /// aligns with the field's bottom-left corner, which in a bottom-anchored
    /// composer (every chat/messaging app) is exactly where the cursor lives —
    /// and, because those composers grow UPWARD, the bottom edge never moves, so
    /// this dock is naturally reflow-stable. Outside the field means it can never
    /// cover the inserted text. No margin room → honest bottom-center.
    private func setReceiptGutterAnchor(_ target: AccessibilityCapture.FieldTarget) {
        let fieldAX = target.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        // Skull center in AX coords: outside-left, at caret line or bottom corner.
        let skullCenterX = fieldAX.minX - Self.receiptGutterGap - Self.receiptSkullSize / 2
        let skullCenterYAX = target.caret?.midY ?? (fieldAX.maxY - Self.receiptSkullSize / 2)

        // Flip to Cocoa and find the screen via the field's flipped rect.
        let flippedField = NSRect(
            x: fieldAX.minX,
            y: primaryHeight - fieldAX.maxY,
            width: fieldAX.width,
            height: fieldAX.height
        )
        let skullCenterY = primaryHeight - skullCenterYAX
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(flippedField) }) ?? NSScreen.main else {
            hudPillPlacement = .bottomCenter
            NotificationCenter.default.post(name: .hudReposition, object: nil)
            return
        }
        let visible = screen.visibleFrame

        // The dock must fit: skull fully on-screen in the margin. A field flush
        // against the screen edge has no gutter — fall home rather than cover text.
        let skullLeft = skullCenterX - Self.receiptSkullSize / 2
        guard skullLeft >= visible.minX + 2,
              skullCenterY - Self.receiptSkullSize / 2 >= visible.minY,
              skullCenterY + Self.receiptSkullSize / 2 <= visible.maxY else {
            Self.placementLog.info("gutter: no margin room → bottom-center (field=\(NSStringFromRect(fieldAX), privacy: .public))")
            hudPillPlacement = .bottomCenter
            NotificationCenter.default.post(name: .hudReposition, object: nil)
            return
        }

        // Window carries the pill at its bottom-leading corner (content padding
        // 6pt horizontal, 8pt vertical) and the hover stack grows up/rightward.
        hudPillPlacement = .aboveField
        let origin = NSPoint(
            x: skullLeft - 6,
            y: (skullCenterY - Self.receiptSkullSize / 2) - 8
        )
        Self.placementLog.info("""
            gutter placement: fieldAX=\(NSStringFromRect(fieldAX), privacy: .public) \
            caret=\(target.caret.map(NSStringFromRect) ?? "nil", privacy: .public) \
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
            || insertionReceipt != nil || transientNotice != nil
        guard pillVisible else {
            pillGoneTicks += 1
            if pillGoneTicks >= 2 { // ≥500ms at 4 Hz — fade is long done
                setHUDAnchor(nil)
            }
            return
        }
        pillGoneTicks = 0

        let current = AccessibilityCapture.focusedEditableFieldTarget()

        if let receipt = insertionReceipt {
            // Receipt phase: attached to the EXACT field the text landed in.
            // Focus elsewhere (window/tab switch, blur) HIDES the pill; focus
            // returning to that element brings it back with a fresh fade
            // window. A hard deadline bounds the receipt's total life —
            // ⌘Z semantics drift as the field accumulates other edits — but
            // a hovered receipt is about to be clicked; let it be.
            if let deadline = receiptDeadline, Date() > deadline, !receiptPillHovered {
                dismissInsertionReceipt(reason: "90s deadline")
                return
            }
            // Mid-cleanup, visibility is owned by the cleanup task's own
            // focus re-verification — don't fight it from the tracker.
            guard !cleanupInProgress else { return }

            if let current, current.isSameField(as: anchor) {
                anchorMissTicks = 0
                // The receipt is attached to the TEXT, not just the field:
                // the first readable tick after the paste lands snapshots the
                // field's content signature, and ANY change to it afterward —
                // Return-to-send, delete, cut, edits — retires the receipt
                // for good. (Grace period: the ⌘V paste is asynchronous.)
                if Date().timeIntervalSince(receipt.createdAt) > 1.0 {
                    if let signature = AccessibilityCapture.fieldContentSignature(current.element) {
                        if let baseline = receiptContentSignature {
                            if signature != baseline {
                                dismissInsertionReceipt(reason: "content changed \(baseline.raw) → \(signature.raw)")
                                return
                            }
                        } else if signature.length == 0 || signature == receiptPreInsertSignature {
                            // Return fired INSIDE the grace window: the field
                            // is already empty / back to its pre-insert state.
                            // The text shipped before we could baseline —
                            // dismiss; never adopt this as the baseline.
                            dismissInsertionReceipt(reason: "text gone before baseline, sig=\(signature.raw)")
                            return
                        } else {
                            Self.receiptLog.info("baseline adopted \(signature.raw, privacy: .public)")
                            receiptContentSignature = signature
                        }
                    } else {
                        // No content attributes at all (Mail's WebKit body). The
                        // caret is the edit tell: it sits at the end of the paste,
                        // and any movement means the user typed or clicked away —
                        // retire the receipt. Geometry (a composer collapsing on
                        // send) is the backstop.
                        if let baseCaret = receiptBaselineCaret {
                            if let c = current.caret,
                               hypot(c.midX - baseCaret.midX, c.midY - baseCaret.midY) > 6 {
                                dismissInsertionReceipt(reason: "caret moved — manual edit")
                                return
                            }
                        } else if let c = current.caret {
                            receiptBaselineCaret = c
                        }
                        let height = current.frame.height
                        if let baseline = receiptBaselineFieldHeight {
                            if height < baseline * 0.55, baseline - height > 20 {
                                dismissInsertionReceipt(reason: "field height collapsed \(Int(baseline)) → \(Int(height))")
                                return
                            }
                        } else {
                            Self.receiptLog.info("no content attributes — geometry fallback, h=\(Int(height), privacy: .public)")
                            receiptBaselineFieldHeight = height
                        }
                    }
                }
                if receiptHidden {
                    Self.receiptLog.info("shown again (field refocused)")
                    receiptHidden = false
                    scheduleReceiptAutoDismiss(receipt)
                }
                // Follow the LIVE cursor. A fixed pin drifts badly in composers
                // that grow/reflow after the paste (every chat + messaging app:
                // the text slides up through the pinned screen point). Tracking
                // lets the receipt settle at the cursor once the reflow finishes
                // and hold there. The dismiss checks above run FIRST, so a genuine
                // user edit still retires it before this repositions — only the
                // post-paste settle (inside the grace window) moves the pill.
                followAnchorGeometry(current)
            } else if current != nil {
                // A single tick resolving a DIFFERENT element is usually WebKit/AX
                // identity flapping (Mail's compose body hands back non-equal
                // element refs across ticks), not a real focus change. Require
                // sustained evidence before hiding — the same grace a missed read
                // gets — so the receipt stops vanishing a beat after it appears.
                anchorMissTicks += 1
                if anchorMissTicks >= 2 { hideReceipt() }
            } else {
                anchorMissTicks += 1
                if anchorMissTicks >= 2 { hideReceipt() }
            }
            return
        }

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

    /// Hide (not dismiss) the receipt: the pill leaves with its field but the
    /// receipt state survives until the deadline, so refocusing the field
    /// brings Cleanup/Undo back. The fade clock stops while hidden.
    private func hideReceipt() {
        guard !receiptHidden else { return }
        Self.receiptLog.info("hidden (field lost focus)")
        receiptHidden = true
        receiptPillHovered = false
        receiptDismissTask?.cancel()
        receiptDismissTask = nil
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
            // No caret either side — but the FIELD may have moved (window drag,
            // composer reflow), and the receipt's gutter dock derives from it.
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

    // MARK: - Post-insertion actions (Cleanup / Undo)

    /// Receipt lifecycle diagnostics — intermittent "pill didn't dismiss on
    /// Return" reports need the decision path visible after the fact:
    /// `log show --process Yorick --last 5m | grep receipt`
    /// (print() is lost for apps launched via Finder/open).
    private static let receiptLog = Logger(subsystem: "com.heyyorick.Yorick", category: "receipt")
    /// HUD placement diagnostics: `log show --process Yorick --info | grep placement`.
    private static let placementLog = Logger(subsystem: "com.heyyorick.Yorick", category: "placement")

    /// The post-insertion receipt (Cleanup/Undo pill) is opt-in: the inserted
    /// words appearing at the cursor are their own confirmation, and with flip
    /// gone the receipt's real payload is just Cleanup. Off by default.
    static let showInsertionReceiptKey = "showInsertionReceipt"

    private func presentInsertionReceipt(captureID: UUID, insertedText: String, targetApp: String?) {
        guard UserDefaults.standard.bool(forKey: Self.showInsertionReceiptKey) else { return }
        let receipt = InsertionReceipt(
            captureID: captureID,
            insertedText: insertedText,
            targetApp: targetApp,
            hint: nil
        )
        insertionReceipt = receipt
        receiptHidden = false
        receiptDeadline = Date().addingTimeInterval(90)
        receiptContentSignature = nil
        receiptBaselineFieldHeight = nil
        receiptBaselineCaret = nil
        rawTranscriptForRevert = nil
        cleanupApplied = false
        // Deliberately no re-anchor here: the pill stays where dictation left it
        // (at the caret) so the transcribing spinner can carry straight through
        // cleanup. It moves to the gutter dock only once the skull replaces the
        // spinner — see autoCleanupLastInsertion.
        // receiptPreInsertSignature is NOT reset here — the insert paths
        // capture it right before pasting, just ahead of this call.
        Self.receiptLog.info("presented target=\(targetApp ?? "nil", privacy: .public) preInsert=\(self.receiptPreInsertSignature?.raw ?? "nil", privacy: .public)")
        scheduleReceiptAutoDismiss(receipt)
        // The setting means "clean my dictation", not "show me a button".
        autoCleanupLastInsertion()
    }

    /// Each VISIBLE stretch gets 10s before the receipt fades — the clock
    /// pauses while the receipt is hidden (field unfocused) so returning to
    /// the tab brings it back with a fresh window.
    private func scheduleReceiptAutoDismiss(_ receipt: InsertionReceipt) {
        receiptDismissTask?.cancel()
        receiptDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, self.insertionReceipt?.id == receipt.id,
                  !self.cleanupInProgress, !self.receiptHidden, !self.receiptPillHovered else { return }
            self.dismissInsertionReceipt(reason: "faded after 10s visible")
        }
    }

    /// Pointer on the receipt suspends the fade clock; leaving restarts a
    /// fresh 10s window.
    func receiptHoverChanged(_ hovering: Bool) {
        receiptPillHovered = hovering
        guard let receipt = insertionReceipt, !receiptHidden else { return }
        if hovering {
            receiptDismissTask?.cancel()
            receiptDismissTask = nil
        } else {
            scheduleReceiptAutoDismiss(receipt)
        }
    }

    func dismissInsertionReceipt(reason: String = "user action") {
        if insertionReceipt != nil {
            Self.receiptLog.info("dismissed: \(reason, privacy: .public)")
        }
        receiptDismissTask?.cancel()
        receiptDismissTask = nil
        insertionReceipt = nil
        receiptHidden = false
        receiptPillHovered = false
        receiptDeadline = nil
        receiptContentSignature = nil
        receiptPreInsertSignature = nil
        receiptBaselineFieldHeight = nil
        cleanupInProgress = false
        // The pill's job at the field is done — go home to bottom-center.
        setHUDAnchor(nil)
    }

    /// The target field must still own focus for ⌘Z / re-paste to hit the
    /// right field — bail loudly rather than undo someone else's edit. With
    /// an anchor this is exact (same AX element); otherwise fall back to
    /// app-name + any-editable-focus.
    private func insertionTargetStillFocused(_ receipt: InsertionReceipt) -> Bool {
        guard let current = AccessibilityCapture.focusedEditableFieldTarget() else { return false }
        if let anchor = hudAnchor {
            return current.isSameField(as: anchor)
        }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName
        return receipt.targetApp == nil || front == receipt.targetApp
    }

    /// Auto-cleanup: with the setting on, the transcript is cleaned the moment it
    /// lands, with no button to press. Raw text is inserted first and only
    /// replaced if cleanup succeeds, so every failure mode (Apple's guardrail
    /// refuses — it reads our own word "pill" as drug content — model
    /// unavailable, focus moved) simply leaves the words as spoken. The receipt's
    /// only job afterwards is Revert.
    func autoCleanupLastInsertion() {
        guard let receipt = insertionReceipt, !cleanupInProgress else { return }
        // Nothing to run and nothing to revert — retire the receipt rather than
        // leave an invisible one parked in state.
        guard LocalIntelligence.isCleanupAvailable else {
            dismissInsertionReceipt(reason: "cleanup unavailable on this Mac")
            return
        }
        guard insertionTargetStillFocused(receipt) else {
            dismissInsertionReceipt(reason: "focus moved before cleanup")
            return
        }
        cleanupInProgress = true
        Task { [weak self] in
            defer { Task { @MainActor in self?.cleanupInProgress = false } }
            do {
                let cleaned = try await LocalIntelligence.cleanupTranscript(receipt.insertedText)
                guard let self, self.insertionReceipt?.id == receipt.id else { return }
                let original = receipt.insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
                // Nothing to show if the model returned the text unchanged.
                guard cleaned.trimmingCharacters(in: .whitespacesAndNewlines) != original else {
                    Self.receiptLog.info("auto-cleanup: no change")
                    self.dismissInsertionReceipt(reason: "auto-cleanup made no change")
                    return
                }
                guard self.insertionTargetStillFocused(receipt) else { return }
                Self.sendUndoKeystroke()
                try? await Task.sleep(nanoseconds: 250_000_000)
                Self.insertTextAtCursor(cleaned + " ")
                self.rawTranscriptForRevert = receipt.insertedText
                self.cleanupApplied = true
                // Spinner is done; the skull takes over, so move it out to the
                // gutter where it can't sit on the text it just rewrote.
                if let anchor = self.hudAnchor { self.setHUDAnchor(anchor) }
                Self.receiptLog.info("auto-cleanup applied")
            } catch {
                // Silent by design: the user still has exactly what they said.
                Self.receiptLog.info("auto-cleanup skipped: \(error.localizedDescription, privacy: .public)")
                guard let self, self.insertionReceipt?.id == receipt.id else { return }
                self.dismissInsertionReceipt(reason: "auto-cleanup unavailable")
            }
        }
    }

    /// Put back exactly what was said, undoing the cleanup edit.
    func revertCleanup() {
        guard let receipt = insertionReceipt, let raw = rawTranscriptForRevert else { return }
        guard insertionTargetStillFocused(receipt) else {
            dismissInsertionReceipt()
            transientNotice = TransientNotice(message: "Focus moved — revert skipped")
            return
        }
        Self.sendUndoKeystroke()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            Self.insertTextAtCursor(raw)
            self.dismissInsertionReceipt(reason: "reverted to raw transcript")
        }
    }

    /// ⌘Z at session level — same mechanism as the ⌘V paste.
    private static func sendUndoKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x06, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    // MARK: - Recording

    private func startCapture() {
        elapsedSeconds = 0
        startedAt = Date()
        transientNotice = nil
        // A new utterance supersedes the last receipt — clear it without
        // resetting the anchor startIfIdle just chose for this session.
        receiptDismissTask?.cancel()
        insertionReceipt = nil
        cleanupInProgress = false
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
            let cleaned = result.transcript
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

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
            let focusedEditableNow = AXIsProcessTrusted() && AccessibilityCapture.hasFocusedEditableElement()
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
                if focusedEditableNow {
                    // Focus may have moved since record start — re-anchor the
                    // pill to the field actually receiving the paste.
                    setHUDAnchor(AccessibilityCapture.focusedEditableFieldTarget() ?? hudAnchor)
                    receiptPreInsertSignature = hudAnchor.flatMap {
                        AccessibilityCapture.fieldContentSignature($0.element)
                    }
                    Self.insertTextAtCursor(cleaned + " ")
                    effects.append(CaptureEffect(kind: .inserted, target: targetApp, timestamp: Date()))
                    presentInsertionReceipt(
                        captureID: captureID,
                        insertedText: cleaned + " ",
                        targetApp: targetApp
                    )
                    print("[Session] Text inserted at cursor")
                } else if AccessibilityCapture.hasAnyFocusedElement() {
                    // Detection couldn't confirm a field, but SOMETHING is focused
                    // — almost always a text field we failed to classify. Trust the
                    // dictation and paste; the transcript is saved to the list
                    // regardless, so a rare misfire costs nothing.
                    setHUDAnchor(nil)
                    Self.insertTextAtCursor(cleaned + " ")
                    effects.append(CaptureEffect(kind: .inserted, target: targetApp, timestamp: Date()))
                    presentInsertionReceipt(
                        captureID: captureID,
                        insertedText: cleaned + " ",
                        targetApp: targetApp
                    )
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

    // MARK: - Text Insertion (from DictationManager)

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]

        init(from pasteboard: NSPasteboard, excluding excludedTypes: Set<NSPasteboard.PasteboardType> = []) {
            items = (pasteboard.pasteboardItems ?? []).compactMap { item in
                var savedItem: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types where !excludedTypes.contains(type) {
                    if let data = item.data(forType: type) {
                        savedItem[type] = data
                    }
                }
                return savedItem.isEmpty ? nil : savedItem
            }
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            guard !items.isEmpty else { return }

            let pasteboardItems = items.map { savedItem in
                let item = NSPasteboardItem()
                for (type, data) in savedItem {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(pasteboardItems)
        }
    }

    private static let dictationPasteboardTokenType = NSPasteboard.PasteboardType("com.heyyorick.Yorick.dictation-token")
    private static let pasteboardRestoreDelay: TimeInterval = 2.0
    private static var pendingPasteboardSnapshot: PasteboardSnapshot?
    private static var pendingPasteboardToken: String?
    private static var pendingPasteboardRestore: DispatchWorkItem?

    /// Insert text at the current cursor position via clipboard + ⌘V.
    private static func insertTextAtCursor(_ text: String) {
        let pasteboard = NSPasteboard.general
        let currentToken = pasteboard.string(forType: dictationPasteboardTokenType)

        // If Yorick already owns the pasteboard from a recent dictation,
        // keep the original snapshot so rapid follow-up dictations still restore
        // the user's real clipboard. If the user changed the clipboard, start a
        // new lease from that current content.
        if pendingPasteboardSnapshot == nil || currentToken != pendingPasteboardToken {
            pendingPasteboardSnapshot = PasteboardSnapshot(
                from: pasteboard,
                excluding: [dictationPasteboardTokenType]
            )
        }
        pendingPasteboardRestore?.cancel()

        let token = UUID().uuidString
        pendingPasteboardToken = token
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(token, forType: dictationPasteboardTokenType)

        // Paste via ⌘V at session level
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .combinedSessionState)

            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cgSessionEventTap)

            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cgSessionEventTap)

            // Keep the transcript on the clipboard long enough for busy target
            // apps to process the paste event. Restore only if the pasteboard
            // still contains our token; never overwrite a user's newer copy.
            let restore = DispatchWorkItem {
                guard pasteboard.string(forType: dictationPasteboardTokenType) == token else {
                    print("[Session] Clipboard changed before restore; leaving user's clipboard intact")
                    if pendingPasteboardToken == token {
                        pendingPasteboardSnapshot = nil
                        pendingPasteboardToken = nil
                        pendingPasteboardRestore = nil
                    }
                    return
                }

                pendingPasteboardSnapshot?.restore(to: pasteboard)
                pendingPasteboardSnapshot = nil
                pendingPasteboardToken = nil
                pendingPasteboardRestore = nil
                print("[Session] Clipboard restored after dictation paste")
            }
            pendingPasteboardRestore = restore
            DispatchQueue.main.asyncAfter(deadline: .now() + pasteboardRestoreDelay, execute: restore)
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

