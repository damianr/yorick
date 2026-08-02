import AppKit
import Foundation

/// Drives one capture from "Send to Linear" to an issue identifier.
///
/// The shape of this state machine IS the design decision: the draft is ready
/// the instant the user presses the button (deterministic, no waiting), the
/// model improves it underneath, and nothing reaches the network until a
/// second, explicit press. The preview is the trust model — what the user
/// approves is byte-for-byte what gets sent.
extension IssueComposer.Input {
    init(_ capture: Capture) {
        self.init(
            transcript: capture.transcript,
            sourceLine: capture.sourceLine,
            windowTitle: capture.windowTitle,
            context: capture.context,
            screenshotCount: capture.screenshotFileNames.count
        )
    }
}

@MainActor
final class LinearSendController: ObservableObject {
    static let shared = LinearSendController()

    enum Phase: Equatable {
        case idle
        /// The proposal is on screen. `composing` is true while the model is
        /// still improving it — the draft is already usable and sendable.
        case proposing(composing: Bool)
        case sending
        case sent(LinearCreatedIssue)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The capture currently under review. Only one at a time — a second
    /// press elsewhere replaces this one, the same no-queue rule the HUD card
    /// follows.
    @Published private(set) var captureID: UUID?
    @Published var draft: LinearIssueDraft?

    private let client = LinearClient()
    private let settings = LinearSettings.shared
    private var composeTask: Task<Void, Never>?

    var workspaces: LinearWorkspaces { settings.workspaces }

    var isComposing: Bool {
        if case .proposing(let composing) = phase { return composing }
        return false
    }

    func isReviewing(_ capture: Capture) -> Bool {
        captureID == capture.id && phase != .idle
    }

    // MARK: - Flow

    /// Open the proposal for a capture. Returns immediately with the
    /// deterministic draft; the model pass, if any, lands a moment later.
    func beginReview(of capture: Capture, store: CaptureStore) {
        guard let teamRef = settings.workspaces.team(id: settings.defaultTeamID)
                ?? settings.workspaces.teams.first else {
            phase = .failed("No Linear team available. Reconnect in Settings.")
            captureID = capture.id
            return
        }
        composeTask?.cancel()
        captureID = capture.id
        let input = IssueComposer.Input(capture)
        let base = IssueComposer.deterministicDraft(
            input, teamID: teamRef.team.id, workspaceID: teamRef.workspaceID
        )
        draft = base

        guard settings.composeWithModel, IssueComposer.isAvailable else {
            phase = .proposing(composing: false)
            return
        }
        phase = .proposing(composing: true)
        let workspaces = settings.workspaces
        let shotURLs = capture.screenshotFileNames.indices.map {
            store.screenshotURL(for: capture, index: $0)
        }
        composeTask = Task { [weak self] in
            // OCR first: what you framed is the strongest subject available,
            // and it reaches surfaces the accessibility tree cannot see at
            // all. Off the main actor, and the deterministic draft is already
            // on screen while this runs.
            var enriched = input
            enriched.screenshotText = await Self.textFromScreenshots(shotURLs)
            let composed = await IssueComposer.compose(enriched, workspaces: workspaces, base: base)
            guard let self, !Task.isCancelled, self.captureID == capture.id else { return }
            // Only adopt the model's work if the user hasn't started editing —
            // text changing under someone's cursor is the exact failure the
            // post-insert cleanup race taught, in a different costume.
            if self.draft == base { self.draft = composed }
            if case .proposing = self.phase { self.phase = .proposing(composing: false) }
        }
    }

    /// Read every attached crop, tallest glyphs first, deduped.
    private static func textFromScreenshots(_ urls: [URL]) async -> [String] {
        var lines: [String] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            lines.append(contentsOf: await ScreenshotText.lines(in: data, limit: 3))
        }
        var seen = Set<String>()
        return lines.filter { seen.insert($0.lowercased()).inserted }
    }

    func cancelReview() {
        composeTask?.cancel()
        composeTask = nil
        captureID = nil
        draft = nil
        phase = .idle
    }

    /// The only network call in the flow, and the only one in the app that
    /// carries user content. Everything it sends is on screen when it fires.
    func send(capture: Capture, store: CaptureStore) {
        guard let draft, phase != .sending else { return }
        phase = .sending
        // Screenshot bytes are read here, on the main actor, so the upload
        // task doesn't reach back into the store.
        let shots: [Data] = capture.screenshotFileNames.indices.compactMap { index in
            try? Data(contentsOf: store.screenshotURL(for: capture, index: index))
        }
        Task { [weak self] in
            do {
                var outgoing = draft
                if !shots.isEmpty, let self {
                    // Uploaded only NOW, on the press — never at preview
                    // time. The trust model is that nothing leaves until you
                    // commit, and an image uploaded to show you a preview
                    // would have already left.
                    outgoing.description = try await self.attachScreenshots(
                        shots, to: draft.description, workspaceID: draft.workspaceID
                    )
                }
                let issue = try await self?.client.createIssue(outgoing)
                guard let self, let issue else { return }
                self.phase = .sent(issue)
                // Record the exit on the capture: the row shows the
                // identifier and stops offering Send, because re-sending
                // would quietly create duplicates.
                var updated = capture
                updated.linearIssue = issue
                store.update(updated)
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Upload the crops and swap the placeholder line for real images.
    ///
    /// A REPLACEMENT, not an addition: the previewed body already says "2
    /// screenshots attached", and the sent body says the same thing in
    /// markdown that renders. Nothing appears in the issue that the preview
    /// didn't account for.
    ///
    /// An upload that fails does NOT fail the send. A ticket without its
    /// screenshot is worth far more than no ticket at all, and the capture
    /// keeps the image either way.
    private func attachScreenshots(_ shots: [Data], to description: String, workspaceID: String) async -> String {
        var markdown: [String] = []
        for (index, data) in shots.enumerated() {
            guard let url = try? await client.uploadFile(
                data, filename: "yorick-screenshot-\(index + 1).jpg",
                contentType: "image/jpeg", workspaceID: workspaceID
            ) else { continue }
            markdown.append("![screenshot \(index + 1)](\(url))")
        }
        guard !markdown.isEmpty else { return description }
        let placeholder = description
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("- ") && $0.hasSuffix("attached") }
            .map(String.init)
        let block = "\n" + markdown.joined(separator: "\n")
        guard let placeholder else { return description + block }
        return description.replacingOccurrences(of: placeholder, with: placeholder + block)
    }

    // MARK: - Connection

    /// One line of feedback for the Settings row. Every outcome sets it —
    /// including cancellation, which used to be swallowed silently and made
    /// a failed connect indistinguishable from a successful one that changed
    /// nothing.
    @Published var connectionStatus: String?

    /// Give up on a connect that will never finish. Linear's authorize page
    /// simply renders an error and never redirects when the client id isn't
    /// valid for the workspace you're signed into — a private OAuth app seen
    /// from a second workspace does exactly that — so the wait needs a door.
    func cancelConnect() {
        Task { await client.cancelConnect() }
    }

    func connect() async {
        connectionStatus = nil
        let known = Set(settings.workspaces.organizationIDs)
        do {
            let workspace = try await client.connect(openURL: { url in
                NSWorkspace.shared.open(url)
            })
            settings.markConnected()
            settings.adopt(workspace: workspace)
            let name = workspace.organizationName ?? "Linear"
            // ADDING is now the normal outcome, so reconnecting the same
            // workspace has to read differently from connecting a new one —
            // otherwise "Add workspace" looks broken when it refreshed
            // exactly the one you already had.
            connectionStatus = known.contains(workspace.organizationID ?? "")
                ? "Refreshed \(name) — already connected."
                : "Connected to \(name)."
        } catch LinearOAuthError.cancelled {
            connectionStatus = "Connection cancelled. Nothing changed."
        } catch {
            connectionStatus = error.localizedDescription
        }
    }

    /// Forget every connection.
    func disconnectAll() async {
        await client.disconnectAll()
        settings.markDisconnected()
        cancelReview()
        connectionStatus = nil
    }

    /// Forget one, leaving the others alone.
    func disconnect(workspaceID: String) async {
        let name = settings.workspaces.workspace(id: workspaceID)?.organizationName ?? "that workspace"
        await client.disconnect(workspaceID: workspaceID)
        settings.remove(workspaceID: workspaceID)
        // A proposal open against a workspace that just went away holds ids
        // nothing can resolve; sending it would fail at the API.
        cancelReview()
        connectionStatus = "Disconnected \(name)."
    }

    /// Re-read the answer key. Cheap, and a stale mirror is the difference
    /// between routing into this quarter's project and last quarter's.
    func refreshWorkspaces() async {
        do {
            for id in settings.workspaces.organizationIDs {
                let refreshed = try await client.fetchWorkspace(workspaceID: id)
                settings.adopt(workspace: refreshed)
            }
        } catch {
            // Surfaces in the Settings row rather than `phase`, which belongs
            // to a capture's proposal and isn't on screen during a refresh.
            connectionStatus = "Couldn't load teams and projects: \(error.localizedDescription)"
        }
    }

    func refreshWorkspacesIfStale() async {
        guard settings.collectsContext, settings.workspaces.isStale else { return }
        await refreshWorkspaces()
    }
}
