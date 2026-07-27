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
                Text(displayText)
                    .font(Theme.mono(12.5))
                    .lineSpacing(6)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Selectable text swallows plain clicks — the simultaneous
                    // recognizer restores click-to-copy while a DRAG still
                    // selects (a tap won't fire across pointer movement).
                    .simultaneousGesture(TapGesture().onEnded { copyRow() })
                // The evidence bundle, one muted line — the list stays plain,
                // but a capture's context should be visible where it lives.
                if let context = capture.context {
                    Text(contextSummary(context))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 13)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(justCopied
                      ? Theme.success.opacity(0.07)
                      : (isHovered ? Theme.bgHover : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { copyRow() }
        .contextMenu {
            if !capture.needsTranscription {
                Button("Copy") { copyRow() }
                if capture.context != nil {
                    Button("Copy with Context") {
                        ClipboardOutput.copy(CaptureRenderer.renderWithContext(capture))
                        captureStore.markActive(capture)
                    }
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

    /// Compact one-liner of the evidence: "infuseflow.app/board · “Migrate
    /// billing…” · pointed at: Overdue tasks +2". One entry per kind; the
    /// pointer sweep shows its first item and a count.
    private func contextSummary(_ context: CaptureContext) -> String {
        var parts: [String] = []
        var seen = Set<String>()
        let pointed = context.facts.filter { $0.kind == "pointedElement" }
        for fact in context.facts where !seen.contains(fact.kind) {
            seen.insert(fact.kind)
            switch fact.kind {
            case "pageURL":
                parts.append(URL(string: fact.value).map { ($0.host ?? "") + $0.path } ?? fact.value)
            case "document":
                parts.append((fact.value as NSString).lastPathComponent)
            case "selection":
                parts.append("“\(fact.value.prefix(60))”")
            case "pointedElement":
                let tail = pointed.count > 1 ? " +\(pointed.count - 1)" : ""
                parts.append("pointed at: \(fact.value.prefix(60))\(tail)")
            default:
                break
            }
        }
        return parts.joined(separator: " · ")
    }

    private func copyRow() {
        guard !capture.needsTranscription else { return }
        ClipboardOutput.copy(displayText)
        captureStore.markActive(capture)
        withAnimation { justCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            withAnimation { justCopied = false }
        }
    }
}
