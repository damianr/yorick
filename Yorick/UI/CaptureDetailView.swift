import AppKit
import SwiftUI

/// One capture, with room. The list stays scannable — what you said and when
/// — and everything you might DO with an utterance lives here.
///
/// This exists because the Linear proposal outgrew a list row: a title field,
/// two pickers, a payload disclosure and four terminal states do not belong
/// inside a 10pt-padded row in a 480pt panel. Managing a capture is a
/// sit-down task now, and it earned a page. The panel is still the shell,
/// though — a page is not a window, and time-to-empty is still the metric.
struct CaptureDetailView: View {
    let capture: Capture
    let captureStore: CaptureStore

    @ObservedObject private var router = PanelRouter.shared
    @ObservedObject private var linear = LinearSettings.shared
    @ObservedObject private var send = LinearSendController.shared
    @Environment(SessionManager.self) private var session
    @State private var justCopied = false

    private var canOfferSend: Bool {
        linear.canSend && capture.linearIssue == nil && !capture.needsTranscription
    }

    private var displayText: String {
        capture.transcript.isEmpty ? capture.bestText : capture.transcript
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                provenance

                if capture.needsTranscription {
                    retryNotice
                } else {
                    words
                    actions
                    if send.isReviewing(capture) {
                        LinearProposalView(capture: capture, controller: send, captureStore: captureStore)
                    }
                    if let context = capture.context, !context.facts.isEmpty {
                        contextSection(context)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Pieces

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(capture.sourceLine)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(DayLabel.string(for: capture.timestamp).lowercased())
                Text(DayLabel.timeFormatter.string(from: capture.timestamp))
                if capture.durationSeconds > 0 {
                    Text("· \(capture.durationSeconds)s")
                }
                // Where the words went first. A fact about this capture, not
                // a category — the disposition was decided when you spoke.
                Text("· \(capture.kind == .dictation ? "typed" : "saved")")
            }
            .font(Theme.mono(9))
            .foregroundStyle(Theme.textTertiary)
        }
    }

    private var words: some View {
        Text(displayText)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var retryNotice: some View {
        Button(action: { session.retryTranscription(capture.id) }) {
            Text("Transcription failed — click to retry. The recording is safe.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.accentAmber)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            CardActionButton(icon: justCopied ? "checkmark" : "doc.on.doc",
                             label: justCopied ? "Copied" : "Copy") {
                ClipboardOutput.copy(displayText)
                justCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    justCopied = false
                }
            }
            if canOfferSend, !send.isReviewing(capture) {
                CardActionButton(icon: "arrow.up.forward.app", label: "Send to Linear") {
                    send.beginReview(of: capture)
                }
            }
            if let issue = capture.linearIssue {
                Button(action: {
                    if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                        Text(issue.identifier)
                            .font(Theme.mono(10.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.success)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(issue.identifier) in Linear")
            }
            Spacer()
            Button(action: {
                // Pop BEFORE deleting: the detail's capture is about to stop
                // existing, and a page rendering a deleted record is a crash
                // waiting for a slow frame.
                router.popToStream()
                captureStore.delete(capture)
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete this capture")
        }
        .animation(.easeOut(duration: 0.15), value: justCopied)
    }

    // MARK: - Context

    /// The evidence, readable. Rendered as labelled rows rather than the
    /// payload's markdown, because this is for a person — the markdown
    /// version is one disclosure away inside the proposal, where it belongs
    /// (that one has to be verbatim; this one has to be legible).
    private func contextSection(_ context: CaptureContext) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("CONTEXT")
                .font(Theme.mono(8.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.textTertiary)
            ForEach(Array(context.facts.enumerated()), id: \.offset) { _, fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.label(for: fact))
                        .font(Theme.mono(8.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(fact.value)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusLg)
                .fill(Color.white.opacity(0.03))
        )
    }

    private static func label(for fact: ContextFact) -> String {
        switch fact.kind {
        case "selection": return "SELECTED"
        case "pageURL": return "PAGE"
        case "document": return "DOCUMENT"
        case "pointedElement": return fact.detail.map { "POINTED AT · \($0.uppercased())" } ?? "POINTED AT"
        default: return fact.kind.uppercased()
        }
    }
}
