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
                Text("✓ copied")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.success)
                    .opacity(justCopied ? 1 : 0)
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
                // Same presentation as the HUD card (CaptureCardBody).
                CaptureCardBody(
                    transcript: displayText,
                    transcriptLineLimit: nil,
                    onTranscriptTap: { copyRow() }
                )
                // The card's actions, as the card shows them — buttons, not
                // hover-revealed text links. Delete stays in the context
                // menu; there's no Dismiss here because the list IS where
                // dismissed cards live.
                HStack(spacing: 8) {
                    CardActionButton(icon: "doc.on.doc", label: "Copy") { copyRow() }
                    Spacer()
                }
                .padding(.top, 2)
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

    // Quiet by request: the disposition tags shouted over the content
    // (bold amber/cyan). Only a capture that needs ACTION keeps its color;
    // the routine tags are tertiary furniture.
    @ViewBuilder
    private var indicator: some View {
        if capture.needsTranscription {
            label("AUDIO SAVED", systemImage: "waveform", color: Theme.accentAmber)
        } else if capture.kind == .dictation {
            let target = capture.effects.last(where: { $0.kind == .inserted })?.target
            label(
                (target ?? "typed").uppercased(),
                systemImage: "arrow.right.to.line",
                color: Theme.textTertiary
            )
        } else {
            label("SAVED", systemImage: "bookmark", color: Theme.textTertiary)
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

    private func flashCopied() {
        captureStore.markActive(capture)
        withAnimation { justCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            withAnimation { justCopied = false }
        }
    }
}
