import SwiftUI

// MARK: - Day Label

enum DayLabel {
    static func string(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "TODAY" }
        if Calendar.current.isDateInYesterday(date) { return "YESTERDAY" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date).uppercased()
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Capture Row
//
// A stream, not a workflow: indicator line on top (where did this land?),
// the full raw text below, and the whole row is the copy button. No state
// to manage — items fade on their own clocks.

struct CaptureRow: View {
    let capture: Capture
    let captureStore: CaptureStore
    /// "today 19:44 · Claude" — day + clock + host app.
    let timeLabel: String

    @Environment(SessionManager.self) private var session
    @State private var isHovered = false
    @State private var justCopied = false

    /// Raw words as spoken — the stream shows what you said, not a rendering.
    private var displayText: String {
        capture.transcript.isEmpty ? capture.bestText : capture.transcript
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                indicator
                Text(justCopied ? "✓ copied" : "click to copy")
                    .font(Theme.mono(9))
                    .foregroundStyle(justCopied ? Theme.success : Theme.textTertiary)
                    .opacity(justCopied || (isHovered && !capture.needsTranscription) ? 1 : 0)
                // The bundle exit, everywhere the transcript exit is: a
                // dismissed card must lose nothing, including the action.
                if isHovered, !justCopied, capture.context != nil, !capture.needsTranscription {
                    Button(action: copyRowWithContext) {
                        Text("· copy with context")
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.textTertiary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(timeLabel)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textTertiary)
            }

            if capture.needsTranscription {
                Button(action: { session.retryTranscription(capture.id) }) {
                    Text("Transcription failed — click to retry. The recording is safe.")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.accentAmber)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Same presentation as the HUD card (CaptureCardBody):
                // readback + raw words, evidence behind "context · n".
                CaptureCardBody(
                    transcript: displayText,
                    readback: capture.readback,
                    context: capture.context,
                    transcriptLineLimit: nil,
                    onTranscriptTap: { copyRow() }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 13)
        .background(
            // Rows read as cards now — a standing background, stronger on
            // hover, matching the HUD card's design language.
            RoundedRectangle(cornerRadius: 10)
                .fill(justCopied
                      ? Theme.success.opacity(0.07)
                      : (isHovered ? Theme.bgHover : Color.white.opacity(0.03)))
        )
        .contentShape(Rectangle())
        .onTapGesture { copyRow() }
        .contextMenu {
            if !capture.needsTranscription {
                Button("Copy") { copyRow() }
                if capture.context != nil {
                    Button("Copy with Context") { copyRowWithContext() }
                }
            }
            Button("Delete", role: .destructive) { captureStore.delete(capture) }
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: justCopied)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(capture.kind == .dictation ? "Typed" : "Saved"): \(capture.transcriptPreview)")
        .accessibilityHint("Click to copy")
    }

    // MARK: - Indicator (where did this land?)

    @ViewBuilder
    private var indicator: some View {
        if capture.needsTranscription {
            label("AUDIO SAVED", systemImage: "waveform", color: Theme.accentAmber)
        } else if capture.kind == .dictation {
            let target = capture.effects.last(where: { $0.kind == .inserted })?.target
            label(
                (target ?? "typed").uppercased(),
                systemImage: "arrow.right.to.line",
                color: .cyan
            )
        } else {
            label("SAVED", systemImage: "bookmark", color: Theme.accentAmber)
        }
    }

    private func label(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(Theme.mono(8.5, weight: .bold))
                .tracking(0.7)
        }
        .foregroundStyle(color)
    }

    private func copyRow() {
        guard !capture.needsTranscription else { return }
        ClipboardOutput.copy(displayText)
        flashCopied()
    }

    private func copyRowWithContext() {
        guard !capture.needsTranscription else { return }
        ClipboardOutput.copy(CaptureRenderer.renderWithContext(capture))
        flashCopied()
    }

    private func flashCopied() {
        captureStore.markActive(capture)
        withAnimation { justCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            withAnimation { justCopied = false }
        }
    }
}
