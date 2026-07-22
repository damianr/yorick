import SwiftUI
import KeyboardShortcuts

struct HUDContentView: View {
    @Environment(SessionManager.self) private var session
    /// Which receipt action the pointer is on — its label renders inline in
    /// the pill (`.help()` tooltips are unreliable on non-activating panels).
    @State private var hoveredReceiptAction: String?

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

                    // Post-insertion receipt: Cleanup / Undo, attached to its
                    // field — hidden on blur, back on refocus.
                    if let receipt = session.insertionReceipt, !session.receiptHidden {
                        insertionReceiptPill(receipt)
                            .transition(.opacity.combined(with: .move(edge: pillEdge)))
                    }

                    // Recording/transcribing pills
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

    private func insertionReceiptPill(_ receipt: InsertionReceipt) -> some View {
        HStack(spacing: 7) {
            if session.cleanupInProgress {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                Text("Cleaning up…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
                if LocalIntelligence.isCleanupAvailable {
                    receiptIcon("wand.and.stars", label: "Clean up") {
                        session.cleanupLastInsertion()
                    }
                }
                receiptIcon("arrow.uturn.backward", label: "Undo") {
                    session.undoLastInsertion()
                }
                receiptIcon("xmark", label: "Dismiss", dim: true) {
                    session.dismissInsertionReceipt()
                }
                if let label = hoveredReceiptAction {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .pillGlass()
        .onHover { hovering in
            session.receiptHoverChanged(hovering)
            if !hovering { hoveredReceiptAction = nil }
        }
        .animation(.easeOut(duration: 0.12), value: hoveredReceiptAction)
    }

    private func receiptIcon(
        _ systemImage: String,
        label: String,
        dim: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(dim ? 0.5 : 0.85))
                .frame(width: 19, height: 19)
                .background(.white.opacity(dim ? 0.08 : 0.15))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredReceiptAction = label
            } else if hoveredReceiptAction == label {
                hoveredReceiptAction = nil
            }
        }
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
                if let flip = KeyboardShortcuts.getShortcut(for: .flipLastUtterance) {
                    Text("\(flip)  insert at cursor instead")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer()
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
    // Quiet by design: logo · dot-grid equalizer · timer · stop. No mode
    // word, no mode color — the pill's POSITION says dictation vs observation.

    private var recordingPill: some View {
        VStack(spacing: 4) {
            HStack(spacing: 9) {
                Image("MenuBarIcon")
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 12, height: 12)
                    .foregroundStyle(.white.opacity(0.75))
                DotEqualizer(level: session.audioLevel)
                Text(session.formattedDuration)
                    .monospacedDigit()
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
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
            if session.showSilenceWarning {
                Text("No audio detected — check your microphone")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .pillGlass()
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
        .pillGlass()
    }
}

// MARK: - Pill Glass

/// Liquid Glass where the OS offers it, classic material capsule elsewhere —
/// plus a gradient rim light and lifted shadow so the pill separates from
/// whatever busy UI it happens to float over.
private struct PillGlass: ViewModifier {
    func body(content: Content) -> some View {
        glassed(content)
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.38), .white.opacity(0.07)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.35), radius: 11, y: 4)
    }

    @ViewBuilder
    private func glassed(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
        }
    }
}

private extension View {
    func pillGlass() -> some View { modifier(PillGlass()) }
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
