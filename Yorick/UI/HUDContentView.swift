import SwiftUI

struct HUDContentView: View {
    @Environment(SessionManager.self) private var session
    /// Which receipt action the pointer is on — its label renders inline in
    /// the pill (`.help()` tooltips are unreliable on non-activating panels).
    /// The receipt rests as a bare skull and expands to its actions on hover —
    /// a quiet marker that doesn't sit over the text it just inserted.
    @State private var receiptHovering = false
    /// The recording pill reveals its stop button only on hover — the EQ already
    /// signals "recording," and push-to-talk means release is the usual stop.
    @State private var recordingHovering = false

    private var isVisible: Bool {
        session.state == .recording ||
        session.state == .transcribing ||
        session.lastSavedCapture != nil ||
        session.transientNotice != nil ||
        (session.insertionReceipt != nil && !session.receiptHidden)
    }

    /// Growth direction: below a field the pill hugs the window's top edge and
    /// grows downward, away from the field; otherwise it grows upward.
    private var pillEdge: Edge { session.hudPillPlacement == .belowField ? .top : .bottom }

    /// Anchored placements are leading-aligned — the pill sits at the field's
    /// top-left corner; bottom-center stays centered.
    private var pillAlignment: Alignment {
        switch session.hudPillPlacement {
        case .bottomCenter: return .bottom
        case .aboveField: return .bottomLeading
        case .belowField: return .topLeading
        }
    }

    var body: some View {
        Group {
            if isVisible {
                VStack(spacing: 8) {
                    // Toast for saved contextual capture
                    if let capture = session.lastSavedCapture {
                        captureSavedToast(capture)
                            .transition(.opacity.combined(with: .move(edge: pillEdge)))
                    }

                    // Notice for a dropped capture (no speech / hallucination)
                    if let notice = session.transientNotice {
                        droppedCaptureNotice(notice)
                            .transition(.opacity.combined(with: .move(edge: pillEdge)))
                    }

                    // Post-insertion receipt: the skull sits in the gutter beside
                    // the inserted text whenever Cleanup is enabled, offering it.
                    if let receipt = session.insertionReceipt, !session.receiptHidden {
                        insertionReceiptPill(receipt)
                            .transition(.opacity.combined(with: .move(edge: pillEdge)))
                    }

                    if session.state == .transcribing {
                        transcribingPill
                            .transition(.opacity.combined(with: .move(edge: pillEdge)))
                    } else if session.state == .recording {
                        recordingPill
                            .transition(.opacity.combined(with: .move(edge: pillEdge)))
                    }
                }
            }
        }
        .animation(.spring(duration: 0.3), value: session.state)
        .animation(.spring(duration: 0.3), value: session.lastSavedCapture?.id)
        .animation(.spring(duration: 0.3), value: session.transientNotice?.id)
        .animation(.spring(duration: 0.3), value: session.insertionReceipt?.id)
        .animation(.spring(duration: 0.3), value: session.receiptHidden)
        .animation(.spring(duration: 0.3), value: session.cleanupInProgress)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: pillAlignment
        )
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }

    // MARK: - Insertion Receipt (Cleanup / Undo at the field)
    //
    // Icon-only actions, same footprint as the recording pill. The hovered
    // action's label renders inline (system tooltips don't reliably appear
    // on non-activating panels), and hover suspends the fade clock.

    // The receipt is a composite: a fixed skull circle that never moves, and —
    // on hover — a column of labeled action pills to its right. The column is
    // bottom-aligned to the circle, so the LAST action (Dismiss) lines up with
    // the skull and earlier actions stack upward, left-aligned.
    private static let receiptPillHeight: CGFloat = 30

    private func insertionReceiptPill(_ receipt: InsertionReceipt) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            skullCircle
            // Exactly one action, whichever one applies: Clean up before, Revert
            // after. Never both, and never while the pass is running.
            if receiptHovering, !session.cleanupInProgress {
                if session.cleanupApplied {
                    receiptOption("arrow.uturn.backward", "Revert to what I said") {
                        session.revertCleanup()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomLeading)))
                } else {
                    receiptOption("wand.and.stars", "Clean up") {
                        session.cleanupLastInsertion()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottomLeading)))
                }
            }
        }
        .onHover { hovering in
            receiptHovering = hovering
            session.receiptHoverChanged(hovering)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: receiptHovering)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: session.cleanupInProgress)
    }

    /// The skull marker, in the gutter beside the inserted text. While cleanup
    /// runs it becomes a spinner IN PLACE — progress without the pill moving or
    /// growing over the text, which is what made the earlier versions feel wrong.
    private var skullCircle: some View {
        ZStack {
            if session.cleanupInProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image("MenuBarIcon")
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: Self.receiptPillHeight, height: Self.receiptPillHeight)
        .pillGlass()
    }

    /// One labeled action as its own pill. Fixed height so the bottom pill
    /// aligns cleanly with the skull circle.
    private func receiptOption(
        _ systemImage: String,
        _ label: String,
        dim: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(dim ? 0.6 : 0.9))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
            }
            .padding(.horizontal, 11)
            .frame(height: Self.receiptPillHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pillGlass()
    }

    // MARK: - Transient Notice (warnings + past-tense receipts)

    private func droppedCaptureNotice(_ notice: TransientNotice) -> some View {
        let isReceipt = notice.style == .receipt
        return HStack(spacing: 10) {
            Image(systemName: isReceipt ? "checkmark.circle.fill" : "mic.slash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isReceipt ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
            }
            if notice.sticky {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .pillGlass()
        .frame(maxWidth: 400)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation { session.transientNotice = nil }
        }
        .onAppear {
            // Sticky notices (failures the user must see) stay until clicked;
            // everything else self-dismisses. Receipts linger a touch longer.
            guard !notice.sticky else { return }
            let noticeId = notice.id
            DispatchQueue.main.asyncAfter(deadline: .now() + (isReceipt ? 4 : 3)) {
                withAnimation {
                    if session.transientNotice?.id == noticeId {
                        session.transientNotice = nil
                    }
                }
            }
        }
    }

    // MARK: - Capture Saved Toast

    private func captureSavedToast(_ capture: Capture) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(capture.appName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text(capture.transcriptPreview)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            // Copy is the recovery path: a dictation that wasn't typed lands here,
            // one obvious click from the clipboard — no hidden keystroke to learn.
            Button(action: {
                ClipboardOutput.copy(capture.transcript)
                session.lastSavedCapture = nil
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 20, height: 20)
                    .background(.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Copy transcript")
            Button(action: {
                session.lastSavedCapture = nil
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 20, height: 20)
                    .background(.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .pillGlass()
        .frame(maxWidth: 400)
        .contentShape(Capsule())
        .onTapGesture {
            // Click toast to open Yorick and show the capture
            session.lastSavedCapture = nil
            NSApp.activate(ignoringOtherApps: true)
        }
        .onAppear {
            // Auto-dismiss after 3 seconds
            let captureId = capture.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    if session.lastSavedCapture?.id == captureId {
                        session.lastSavedCapture = nil
                    }
                }
            }
        }
    }

    // MARK: - Recording Pill
    //
    // Quiet by design: logo · dot-grid equalizer, with the stop button revealed
    // on hover. No timer, no mode word, no mode color — the EQ says "recording"
    // and the pill's POSITION says dictation vs observation.

    private var recordingPill: some View {
        VStack(spacing: 4) {
            HStack(spacing: 9) {
                Image("MenuBarIcon")
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 12, height: 12)
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(height: 19) // seat at button height so hover adds no vertical jump
                DotEqualizer(level: session.audioLevel)
                if recordingHovering {
                    Button(action: { session.stopIfRecording() }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 19, height: 19)
                            .background(.white.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if session.showSilenceWarning {
                Text("No audio detected — check your microphone")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        // Constant padding so the logo + EQ never shift on hover — the stop
        // button simply appends on the right, the pill grows rightward.
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .pillGlass(corners: .pointer)
        .onHover { recordingHovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: recordingHovering)
        .animation(.easeOut(duration: 0.15), value: session.showSilenceWarning)
    }

    // MARK: - Transcribing Pill

    private var transcribingPill: some View {
        HStack(spacing: 9) {
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .frame(width: 12, height: 12)
                .foregroundStyle(.white.opacity(0.75))
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
            Button(action: { session.cancelProcessing() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 19, height: 19)
                    .background(.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel transcription")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .pillGlass(corners: .pointer)
    }
}

// MARK: - Pill Glass

/// The pill's silhouette.
enum PillCorners {
    /// Fully round ends at any height.
    case capsule
    /// Same radius on all four corners.
    case uniform(CGFloat)
    /// Round right end, gently rounded top-left, near-square bottom-left — the
    /// corner seated at the caret, so the pill reads as marking the insertion
    /// point. Radii are derived from the actual height: the first attempt passed
    /// an oversized value and let SwiftUI clamp it, which handed the top-left
    /// whatever space was left over and made the left edge look lopsided.
    case pointer
}

private struct PillShape: InsettableShape {
    var corners: PillCorners
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let full = r.height / 2          // a true capsule end at this height
        let radii: RectangleCornerRadii
        switch corners {
        case .capsule:
            radii = .init(topLeading: full, bottomLeading: full,
                          bottomTrailing: full, topTrailing: full)
        case .uniform(let v):
            let c = min(v, full)
            radii = .init(topLeading: c, bottomLeading: c, bottomTrailing: c, topTrailing: c)
        case .pointer:
            radii = .init(topLeading: min(12, full), bottomLeading: min(4, full),
                          bottomTrailing: full, topTrailing: full)
        }
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> PillShape {
        PillShape(corners: corners, inset: inset + amount)
    }
}

/// Dark capsule with a gradient rim light and a lifted shadow, so the pill
/// separates from whatever busy UI it happens to float over.
private struct PillGlass: ViewModifier {
    var corners: PillCorners = .capsule
    private var shape: PillShape { PillShape(corners: corners) }

    func body(content: Content) -> some View {
        glassed(content)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.30), .white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            )
            .compositingGroup()
            // Tight, defined shadow — the old radius-11 cloud smudged badly on
            // white backgrounds (Pages, a white webpage). Two layers: a soft
            // lift plus a crisp contact edge that reads on any backdrop.
            .shadow(color: .black.opacity(0.26), radius: 5, y: 2)
            .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
    }

    /// A DARK capsule, not light glass — and explicitly NOT Liquid Glass, whose
    /// `.regular` material re-adapts to a bright backdrop and washed the pill out
    /// (it "flashed black then went light" over a white page). An opaque-enough
    /// dark fill over a faint frost keeps white text and icons legible on ANY
    /// background, the way the macOS system HUD does — and it holds.
    private func glassed(_ content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Color.black.opacity(0.78))
                }
            }
            .clipShape(shape)
    }
}

private extension View {
    func pillGlass(corners: PillCorners = .capsule) -> some View {
        modifier(PillGlass(corners: corners))
    }
}

// MARK: - Dot Equalizer

/// A grid of dots (4 high) whose columns fill from the bottom with the mic
/// level — a center-weighted profile plus level-keyed shimmer makes columns
/// dance independently, so it reads as an equalizer rather than a meter.
private struct DotEqualizer: View {
    let level: Float
    private let rows = 4
    private let cols = 8
    private let dot: CGFloat = 2.5
    private let gap: CGFloat = 2
    private static let profile: [Double] = [0.5, 0.72, 0.9, 1.0, 1.0, 0.9, 0.72, 0.5]

    var body: some View {
        HStack(spacing: gap) {
            ForEach(0..<cols, id: \.self) { col in
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { row in
                        Circle()
                            .fill(.white)
                            .opacity(dotOpacity(col: col, row: row))
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// Rows render top-down; a column lights from the bottom like a meter.
    private func dotOpacity(col: Int, row: Int) -> Double {
        let clamped = Double(min(max(level, 0), 1))
        // Deterministic per-column shimmer keyed off the level so columns
        // move independently on every audio tick without stored state.
        let shimmer = 0.75 + 0.35 * (sin(Double(col) * 1.7 + clamped * 47.0) * 0.5 + 0.5)
        let amplitude = clamped * Self.profile[col % Self.profile.count] * shimmer
        let lit = Int((amplitude * Double(rows)).rounded(.up))
        let rowFromBottom = rows - 1 - row
        return rowFromBottom < lit ? 0.95 : 0.18
    }
}
