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
    @State private var attaching = false
    @State private var justCopiedTicket = false

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
                    linearHint
                    if send.isReviewing(capture) {
                        LinearProposalView(capture: capture, controller: send, captureStore: captureStore)
                    }
                    if LinearSettings.shared.collectsContext || !capture.screenshotFileNames.isEmpty {
                        screenshots
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
            // Always offered, connected or not. A framed ticket pasted into
            // a coding agent is its own validated workflow, so this is not
            // the consolation prize for having no integration — it is the
            // exit that needs nothing.
            CardActionButton(icon: justCopiedTicket ? "checkmark" : "doc.text",
                             label: justCopiedTicket ? "Copied" : "Copy ticket") {
                // copyBundle, not copy: it puts plain text, PNG, HTML with
                // the image inline, and RTF on the pasteboard at once. A
                // terminal takes the text; Claude Mac and Linear's web editor
                // take the rich version and render the crop with it. Built in
                // the enrichment era for exactly this paste.
                let images = capture.screenshotFileNames.indices.compactMap {
                    captureStore.screenshotImage(for: capture, index: $0)
                }
                if images.isEmpty {
                    ClipboardOutput.copy(ticketText)
                } else {
                    ClipboardOutput.copyBundle(text: ticketText, images: images)
                }
                justCopiedTicket = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    justCopiedTicket = false
                }
            }
            if canOfferSend, !send.isReviewing(capture) {
                CardActionButton(icon: "arrow.up.forward.app", label: "Send to Linear") {
                    send.beginReview(of: capture, store: captureStore)
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
        .animation(.easeOut(duration: 0.15), value: justCopiedTicket)
    }

    /// The whole ticket as markdown: the title Yorick would have used, then
    /// the same body a Linear issue gets.
    private var ticketText: String {
        TicketClipboard.text(
            title: TitleComposer.deterministicTitle(IssueComposer.Input(capture)),
            transcript: displayText,
            sourceLine: capture.sourceLine,
            windowTitle: capture.windowTitle,
            context: capture.context,
            screenshotCount: capture.screenshotFileNames.count
        )
    }

    /// Shown only when there is no integration: the education lives HERE,
    /// beside the artifact it describes, rather than in a fifth onboarding
    /// step about a feature most people will never switch on. Same principle
    /// as the catch teaching itself the first time it fires.
    @ViewBuilder
    private var linearHint: some View {
        if !linear.isConnected, LinearConfig.isConfigured, !capture.needsTranscription {
            Button(action: { router.push(.settings) }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text("Yorick can file these into Linear for you")
                        .font(Theme.mono(9.5))
                }
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Set up the Linear integration")
        }
    }

    // MARK: - Screenshots

    /// Crops taken while you were talking, deletable before the capture goes
    /// anywhere. A screenshot is the most revealing thing this app can hold,
    /// so removing one has to be a visible, one-click affordance sitting on
    /// the image itself — not a context menu you'd have to guess at.
    private var screenshots: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("SCREENSHOTS")
                    .font(Theme.mono(8.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                // The pill's button is gone for dictations because pressing it
                // blurred the field. Here there is no field to lose, so the
                // case it served — realising afterwards that a picture would
                // have said it — is still covered.
                Button(action: attachScreenshot) {
                    HStack(spacing: 4) {
                        Image(systemName: "camera")
                            .font(.system(size: 9, weight: .semibold))
                        Text(attaching ? "Framing…" : "Add")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.glow)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(attaching)
                .help("Drag a region to attach it to this capture")
            }
            ForEach(capture.screenshotFileNames.indices, id: \.self) { index in
                if let image = captureStore.screenshotImage(for: capture, index: index) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusMd)
                                .strokeBorder(Theme.borderSubtle, lineWidth: 1)
                        )
                        .overlay(alignment: .topTrailing) {
                            HStack(spacing: 4) {
                                // The ticket text can't carry an image, so
                                // the image carries itself — one click, then
                                // paste it wherever the text went.
                                Button(action: { ClipboardOutput.copy(image: image) }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .frame(width: 18, height: 18)
                                        .background(Color.black.opacity(0.55))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Copy this image")
                                Button(action: { captureStore.removeScreenshot(from: capture, index: index) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .frame(width: 18, height: 18)
                                        .background(Color.black.opacity(0.55))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Remove this screenshot")
                            }
                            .padding(6)
                        }
                }
            }
        }
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

    private func attachScreenshot() {
        guard !attaching else { return }
        attaching = true
        Task { @MainActor in
            defer { attaching = false }
            do {
                let data = try await ScreenCapture.selectRegion()
                captureStore.addScreenshot(to: capture, data: data)
            } catch ScreenCapture.Failure.cancelled {
                // Escape is a decision.
            } catch {
                // The capture is untouched and the page still shows what it
                // had; a banner here would be louder than the failure.
                print("[Detail] Screenshot failed: \(error)")
            }
        }
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
