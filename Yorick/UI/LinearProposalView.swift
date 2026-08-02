import SwiftUI

/// The proposal: what Yorick is about to file, before it files it.
///
/// This view is the whole feature. The moment the design is built around is
/// seeing a rambled sentence come back as a titled issue in the right project
/// — and seeing it BEFORE anything is sent, so a wrong guess costs a
/// keystroke instead of a bad ticket. Every field is editable, and the exact
/// text that will be transmitted is one disclosure away.
struct LinearProposalView: View {
    let capture: Capture
    @ObservedObject var controller: LinearSendController
    var captureStore: CaptureStore

    @State private var showingPayload = false
    /// The title field takes focus the moment the proposal opens.
    ///
    /// Measured, not assumed: the on-device model cannot reliably write an
    /// issue title from rambling speech. Two prompts produced two failure
    /// modes — one lifted a sentence verbatim ("I don't really need this
    /// section"), the other wrote something terse and WRONG ("Emphasize
    /// Ums", from a note asking to de-emphasize). A confident wrong title is
    /// worse than an obviously raw one, so the design stops pretending the
    /// model settles this: it proposes, the cursor is already in the field,
    /// and correcting is the expected gesture rather than the recovery.
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch controller.phase {
            case .sent(let issue):
                sentRow(issue)
            case .failed(let message):
                failureRow(message)
            default:
                proposalForm
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusLg)
                .fill(Theme.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusLg)
                        .strokeBorder(Theme.borderSubtle, lineWidth: 1)
                )
        )
    }

    // MARK: - Form

    @ViewBuilder
    private var proposalForm: some View {
        if let draft = Binding($controller.draft) {
            HStack(spacing: 6) {
                Text("SEND TO LINEAR")
                    .font(Theme.mono(9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                if controller.isComposing {
                    // The draft below is already complete and sendable; this
                    // only says a better one may replace it. Never a spinner
                    // over an empty form.
                    Text("· reading it")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.glow)
                }
                Spacer()
            }

            TextField("Title", text: draft.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...3)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMd)
                        .fill(Theme.bgInput)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusMd)
                                .strokeBorder(titleFocused ? Theme.glow.opacity(0.5) : .clear, lineWidth: 1)
                        )
                )
                .focused($titleFocused)
                .onAppear { titleFocused = true }

            // The escape hatch from a bad generated title, in one click.
            // Your own words are never wrong — only unpolished — so they are
            // always worth being one gesture away.
            if !deterministicTitle.isEmpty, draft.wrappedValue.title != deterministicTitle {
                Button(action: { draft.wrappedValue.title = deterministicTitle }) {
                    Text("Use my words instead")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(deterministicTitle)
            }

            HStack(spacing: 8) {
                teamPicker(draft)
                projectPicker(draft)
            }

            disclosureRow

            HStack(spacing: 8) {
                Button(action: { controller.send(capture: capture, store: captureStore) }) {
                    HStack(spacing: 5) {
                        if controller.phase == .sending {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        Text(controller.phase == .sending ? "Sending…" : "Create issue")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.bgPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.bone))
                }
                .buttonStyle(.plain)
                .disabled(controller.phase == .sending || draft.wrappedValue.title.isEmpty)

                Button("Cancel") { controller.cancelReview() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
        }
    }

    /// Teams from EVERY connected workspace, qualified only when more than
    /// one is connected. Picking a team also picks the workspace, so there is
    /// no separate workspace control to get out of sync with this one.
    private func teamPicker(_ draft: Binding<LinearIssueDraft>) -> some View {
        let workspaces = controller.workspaces
        let qualify = workspaces.needsWorkspaceQualifier
        return Picker("", selection: draft.teamID) {
            ForEach(workspaces.teams) { ref in
                Text(ref.label(qualified: qualify)).tag(ref.team.id)
            }
        }
        .labelsHidden()
        .font(.system(size: 11))
        .onChange(of: draft.wrappedValue.teamID) { _, newTeam in
            // The workspace follows the team, always — a draft whose
            // workspace disagreed with its team would be created with the
            // wrong token and fail at the API with something unhelpful.
            draft.wrappedValue.workspaceID = workspaces.team(id: newTeam)?.workspaceID ?? ""
            // A project belongs to its teams; switching teams must not leave
            // a project selected that the new team can't see.
            let valid = workspaces.projects(forTeam: newTeam).map(\.id)
            if let project = draft.wrappedValue.projectID, !valid.contains(project) {
                draft.wrappedValue.projectID = nil
            }
        }
    }

    private func projectPicker(_ draft: Binding<LinearIssueDraft>) -> some View {
        let projects = controller.workspaces.projects(forTeam: draft.wrappedValue.teamID)
        return Picker("", selection: draft.projectID) {
            Text("No project").tag(String?.none)
            ForEach(projects) { project in
                Text(project.name).tag(String?.some(project.id))
            }
        }
        .labelsHidden()
        .font(.system(size: 11))
        .disabled(projects.isEmpty)
    }

    // MARK: - What gets sent

    /// The payload, verbatim. Collapsed by default — simplest first — but
    /// never more than one click away, because "nothing leaves your Mac
    /// unless you send it" is only checkable if you can see what leaves.
    @ViewBuilder
    private var disclosureRow: some View {
        Button(action: { withAnimation(.easeOut(duration: 0.15)) { showingPayload.toggle() } }) {
            HStack(spacing: 4) {
                Image(systemName: showingPayload ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                Text(payloadLabel)
                    .font(Theme.mono(9.5))
            }
            .foregroundStyle(Theme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showingPayload, let draft = controller.draft {
            ScrollView {
                Text(draft.description)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.bgInput))
        }
    }

    /// What the title would be with no model involved: the first sentence of
    /// what you said, capped at a word boundary.
    private var deterministicTitle: String {
        LinearDescriptionBuilder.fallbackTitle(transcript: capture.transcript)
    }

    private var payloadLabel: String {
        let facts = capture.context?.factCount ?? 0
        return facts == 0
            ? "exactly what gets sent"
            : "exactly what gets sent · \(facts) context \(facts == 1 ? "fact" : "facts")"
    }

    // MARK: - Terminal states

    private func sentRow(_ issue: LinearCreatedIssue) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.success)
            VStack(alignment: .leading, spacing: 1) {
                Text(issue.identifier)
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(issue.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Open") {
                if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
                controller.cancelReview()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.glow)
        }
    }

    private func failureRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Theme.error)
                .fixedSize(horizontal: false, vertical: true)
            // Nothing was lost — the capture is still in the list, exactly as
            // it was. Say so rather than leaving the user to wonder.
            Text("Your capture is still here. Nothing was sent.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 8) {
                Button("Try again") { controller.beginReview(of: capture, store: captureStore) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.glow)
                Button("Dismiss") { controller.cancelReview() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
