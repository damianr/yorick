import SwiftUI

struct HUDContentView: View {
    @Environment(SessionManager.self) private var session
    /// The recording pill reveals its stop button only on hover — the EQ already
    /// signals "recording," and push-to-talk means release is the usual stop.
    @State private var recordingHovering = false
    /// The saved-capture card's fade clock, cancelled while hovered.
    @State private var cardDismissTask: Task<Void, Never>?
    @State private var cardHovering = false

    private var isVisible: Bool {
        (session.state == .recording && session.hudReady) ||
        session.state == .transcribing ||
        session.lastSavedCapture != nil ||
        session.transientNotice != nil
    }

    /// Growth direction: content hugs its anchored edge and grows away from it.
    private var pillEdge: Edge {
        switch session.hudPillPlacement {
        case .belowField: return .top
        case .bottomCenter: return HUDPlacement.unanchoredAtTop ? .top : .bottom
        case .aboveField: return .bottom
        }
    }

    /// Anchored placements are leading-aligned — the pill sits at the field's
    /// top-left corner; the unanchored pill centers on its trial edge.
    private var pillAlignment: Alignment {
        switch session.hudPillPlacement {
        case .bottomCenter: return HUDPlacement.unanchoredAtTop ? .top : .bottom
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
                            // The card GROWS out of the pill's spot rather
                            // than arriving from off-edge — pill becomes card.
                            .transition(.scale(scale: 0.85, anchor: pillEdge == .top ? .top : .bottom)
                                .combined(with: .opacity))
                    }

                    // Notice for a dropped capture (no speech / hallucination)
                    if let notice = session.transientNotice {
                        droppedCaptureNotice(notice)
                            .transition(.opacity.combined(with: .move(edge: pillEdge)))
                    }

                    if session.state == .recording || session.state == .transcribing {
                        sessionPill
                            .transition(.opacity.combined(with: .move(edge: pillEdge)))
                    }
                }
            }
        }
        .animation(.spring(duration: 0.3), value: session.state)
        .animation(.spring(duration: 0.3), value: session.lastSavedCapture?.id)
        .animation(.spring(duration: 0.3), value: session.transientNotice?.id)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: pillAlignment
        )
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
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

    // MARK: - Saved-Capture Card
    //
    // Card v1 of the enrichment plan: the saved toast grown into an exit
    // ramp — the words worth reading, where they were spoken, and the exits.
    // Offer, never demand: it fades on its own, hover holds it, a newer
    // capture replaces it (no queue), and it never takes keyboard focus.
    // Dismiss always means "it's in the list; later" — nothing is lost.

    private func captureSavedToast(_ capture: Capture) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                Text(capture.sourceLine)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 12)
            }
            // Shared presentation with the saved list: the words, exactly
            // as spoken.
            CaptureCardBody(
                transcript: capture.transcript,
                transcriptLineLimit: 4
            )
            HStack(spacing: 8) {
                // Copy is the recovery path: a dictation that wasn't typed
                // lands here, one obvious click from the clipboard.
                CardActionButton(icon: "doc.on.doc", label: "Copy") {
                    ClipboardOutput.copy(capture.transcript)
                    session.lastSavedCapture = nil
                }
                Spacer()
                CardActionButton(icon: "xmark", label: "Dismiss") {
                    session.lastSavedCapture = nil
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .pillGlass(corners: .uniform(14))
        .frame(maxWidth: 400)
        .contentShape(Rectangle())
        .onTapGesture {
            // Click anywhere else on the card to open Yorick at the list.
            session.lastSavedCapture = nil
            NSApp.activate(ignoringOtherApps: true)
        }
        .onHover { hovering in
            // Hover holds the card (the skull's pattern); leaving restarts a
            // short clock so it never lingers after you've looked away.
            cardHovering = hovering
            if hovering {
                cardDismissTask?.cancel()
            } else {
                scheduleCardDismiss(capture.id, after: 2.5)
            }
        }
        .onAppear {
            scheduleCardDismiss(capture.id, after: 6)
        }
        // New identity per capture, so a replacing card restarts its own clock.
        .id(capture.id)
    }




    private func scheduleCardDismiss(_ captureId: UUID, after seconds: Double) {
        cardDismissTask?.cancel()
        cardDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, session.lastSavedCapture?.id == captureId else { return }
            withAnimation { session.lastSavedCapture = nil }
        }
    }

    // MARK: - Recording Pill
    //
    // Quiet by design: logo · dot-grid equalizer, with the stop button revealed
    // on hover. No timer, no mode word, no mode color — the EQ says "recording"
    // and the pill's POSITION says dictation vs observation.

    /// The skull mark — the new logo as a template vector (single evenodd
    /// path, so the eyes and nose are true cutouts and the face survives
    /// tinting), white like every pill glyph, slightly larger than the old
    /// 12pt mark so the face actually reads at pill size. Falls back to the
    /// legacy glyph if the asset is ever missing. The full-color 3D version
    /// takes over this slot when the look-around skull lands.
    private func skullMark(_ size: CGFloat, templateOpacity: Double = 0.75) -> some View {
        // ONE mark asset app-wide: MenuBarIcon carries the skull for the
        // menu bar, titlebar, onboarding, and these pills alike.
        Image("MenuBarIcon")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.white.opacity(templateOpacity))
    }

    /// The squared corner means "seated at your insertion point," so only a
    /// field-anchored pill gets to wear it — with the seated corner facing
    /// the caret. Bottom-center (saving, or an opaque field) is a full
    /// capsule: shape differentiates the two futures the same way position
    /// already does.
    private var recordingCorners: PillCorners {
        // An approximate anchor (single-line leading edge) never wears the
        // pointer corner — that corner claims the exact insertion point.
        guard !session.hudAnchorApproximate else { return .capsule }
        switch session.hudPillPlacement {
        case .bottomCenter: return .capsule
        case .aboveField: return .pointer
        case .belowField: return .pointerBelow
        }
    }

    // MARK: - Session Pill (recording + transcribing, one identity)
    //
    // One pill, states within: recording (skull · status · EQ) crossfades
    // into transcribing ("Transcribing…" · spinner) with no view swap — the
    // old two-pill handoff read as a glitch. The unanchored pill is
    // deliberately LOUDER than the field pill: bigger skull and bone status
    // text — it sits at a screen edge with no caret to mark, so it has to
    // earn the glance. The field-anchored pill stays compact; near a caret,
    // small is right.

    private var sessionPill: some View {
        let transcribing = session.state == .transcribing
        let unanchored = session.hudPillPlacement == .bottomCenter
        return VStack(spacing: 4) {
            HStack(spacing: unanchored ? 10 : 9) {
                skullMark(16)
                    .frame(height: 19) // seat at button height so hover adds no vertical jump
                if unanchored {
                    Text(transcribing
                         ? (session.cleanupRunning ? "Cleaning up…" : "Transcribing…")
                         : "Listening…")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.bone)
                        .lineLimit(1)
                }
                if transcribing {
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
                } else {
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
            }
            if session.showSilenceWarning, !transcribing {
                Text("No audio detected — check your microphone")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        // Constant padding so the mark + EQ never shift on hover — buttons
        // append on the right, the pill grows rightward.
        .padding(.horizontal, unanchored ? 14 : 11)
        .padding(.vertical, unanchored ? 8 : 5)
        // The halo BREATHES with the voice while recording — same signal as
        // the equalizer, both in Theme.glow, so meter and glow move
        // together; while transcribing it holds at fixed intensity. Glass
        // (background, rim, shadows) is the shared recipe in PillGlass.
        .pillGlass(
            corners: recordingCorners,
            haloIntensity: transcribing ? 0.5 : Double(min(max(session.audioLevel, 0), 1))
        )
        .onHover { recordingHovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: recordingHovering)
        .animation(.spring(duration: 0.3), value: transcribing)
        .animation(.easeOut(duration: 0.15), value: session.showSilenceWarning)
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
    /// Mirror of `pointer` for a pill sitting BELOW its field: the seated
    /// (near-square) corner is the top-left, pointing up at the caret.
    case pointerBelow
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
        case .pointerBelow:
            radii = .init(topLeading: min(4, full), bottomLeading: min(12, full),
                          bottomTrailing: full, topTrailing: full)
        }
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: r)
    }

    func inset(by amount: CGFloat) -> PillShape {
        PillShape(corners: corners, inset: inset + amount)
    }
}

/// Dark capsule with a gradient rim light and a lifted shadow, so the pill
/// separates from whatever busy UI it happens to float over. ONE recipe for
/// every surface — session pill, capture card, notices: same background
/// opacity, same bone rim, same shadows (playground-tuned 2026-07-30). The
/// only per-surface option is the HALO: pass `haloIntensity` to add the
/// Theme.glow ring (the session pill breathes it with the voice); nil means
/// no halo, everything else identical.
private struct PillGlass: ViewModifier {
    var corners: PillCorners = .capsule
    /// 0…1 scales the glow halo with the live audio level; nil = no halo.
    var haloIntensity: Double?
    private var shape: PillShape { PillShape(corners: corners) }

    func body(content: Content) -> some View {
        let intensity = min(max(haloIntensity ?? 0, 0), 1)
        return glassed(content)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Theme.bone.opacity(0.26), Theme.bone.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .compositingGroup()
            // Tight, defined shadow — the old radius-11 cloud smudged badly on
            // white backgrounds (Pages, a white webpage). Two layers: a soft
            // lift plus a crisp contact edge that reads on any backdrop.
            .shadow(color: .black.opacity(0.21), radius: 5, y: 0)
            .shadow(color: .black.opacity(0.16), radius: 1.25, y: 0.5)
            .shadow(
                color: haloIntensity == nil
                    ? .clear
                    : Theme.glow.opacity(0.16 + 0.52 * intensity),
                radius: 10 + 4.5 * intensity
            )
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
                    shape.fill(Color.black.opacity(0.85))
                }
            }
            .clipShape(shape)
    }
}

private extension View {
    func pillGlass(corners: PillCorners = .capsule, haloIntensity: Double? = nil) -> some View {
        modifier(PillGlass(corners: corners, haloIntensity: haloIntensity))
    }
}

// MARK: - Dot Equalizer

/// A grid of dots (4 high) whose columns fill from the bottom with the mic
/// level — a center-weighted profile plus level-keyed shimmer makes columns
/// dance independently, so it reads as an equalizer rather than a meter.
private struct DotEqualizer: View {
    let level: Float
    /// Theme.glow, pinned to the halo — the voice meter and the glow speak
    /// the same color, and that color never touches text.
    var tint: Color = Theme.glow
    private let rows = 4
    private let cols = 6
    private let dot: CGFloat = 2.5
    private let gap: CGFloat = 2
    /// Center-weighted profile, resampled for 6 columns from the original
    /// 8-wide curve (playground-tuned).
    private static let profile: [Double] = [0.5, 0.79, 0.98, 0.98, 0.79, 0.5]

    var body: some View {
        HStack(spacing: gap) {
            ForEach(0..<cols, id: \.self) { col in
                VStack(spacing: gap) {
                    ForEach(0..<rows, id: \.self) { row in
                        Circle()
                            .fill(tint)
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
