# Send to Linear — plan

Successor to `docs/enrichment-plan.md` (preserved on `enrichment-exits-v2`, which is an
ancestor of `main`; retrieve any file with `git show enrichment-exits-v2:<path>`).
Nothing here has shipped.

## What this reverses, and why

The enrichment plan cut this feature explicitly:

> Direct integrations (Linear, Notion) are **cut from this plan** — a user-initiated
> network exit reopens the checkable "no network calls" positioning commitment.

Reversed deliberately. The positioning commitment survives in the form that actually
matters: Yorick sends nothing on its own. A capture leaves only when the user presses a
button, to a destination the user connected, after seeing exactly what will be sent.
"No background network" stays literally true and Little-Snitch-checkable; "nothing ever
leaves your Mac" narrows to "nothing leaves unless you send it."

Two other reversals ride along:

- **Screen context returns.** The 2026-07-29 removal made "never reads your screen" a
  headline claim. That claim is retired: reading the screen locally was never the privacy
  risk — transmission is, and transmission is now manual, per-item, and previewed. The
  site, README, and onboarding copy change with this.
- **The on-device model moves from garnish to load-bearing.** Justified by a change in
  the task, not the model — see below.

## Design stance

**Linear's API is a sink, not a brain.** Researched and confirmed (2026-07-31): there is
no public "POST unstructured text, get a well-formed ticket" endpoint. Linear's Agent
APIs run the other direction — your app registers as an agent and responds to webhooks,
which a local Mac app with no public endpoint structurally cannot do. Every Linear-side
AI surface that *could* refine a raw capture — Triage Intelligence, Agent automations on
triage, Loops — is **Business/Enterprise only**. Building the magic on a plan tier most
users won't have is not an option for a free app.

**So the composition happens on-device, and it is safe now because the choice set became
real.** v1 enrichment asked a weak model to invent a taxonomy — kinds, tags, titles —
with no right answer and no way to check the output. Here the model picks a team and
project from the user's ACTUAL Linear workspace, fetched from the API: guided generation
over an enum of real IDs, typically fewer than a dozen options, with a right answer that
the user can see and correct before anything is sent. Constrained multiple choice is the
one shape the on-device model is reliably good at. The open-ended half (the title) is
small, previewed, and editable, and its failure mode is a mediocre title on an issue the
user already approved — not silently replacing someone's words, which is what the
few-shot regression did.

**Preview before send, always.** The "it understood me" moment happens BEFORE the
network call, not after. This is what makes a wrong pick cost one click instead of a bad
ticket, and it is the reason the model is allowed on this path at all.

**Every exit degrades deterministically.** Model timeout, guardrail refusal, no Apple
Intelligence, or a workspace fetch failure all fall back to the same thing: raw
transcript, no title, into Triage. Linear handles untitled triage items natively. An
exit that cannot degrade does not ship.

**Anti-goals:** no background network of any kind; no sending without an explicit press;
no screenshots or Screen Recording (AX only, as before); no auto-filing on the Linear
side; no second hotkey; nothing on the dictation hot path.

## Architecture

**Layer B — Context bundle (revived).** `ContextCollector.swift` (259 lines) and
`CaptureContext.swift` (96 lines) come back from `enrichment-exits-v2` largely intact:
versioned `Codable` bundle, raw AX facts with provenance, never a summary, every field
optional, pointer-freshness gating via `pointerParked`, bounded acquisition off the
insert path. Everything the original plan's rungs 1–4 specified. Two changes: the bundle
is now also a *transmission* payload, so the length caps and the secure-field exclusions
become load-bearing rather than hygienic; and the card must show the bundle verbatim
before send, since previewing what leaves is the whole trust model.

**Layer W — Workspace mirror (new).** On connect, and refreshed lazily, Yorick fetches
teams and projects (id, name, description, team) via GraphQL and caches them locally.
This is the answer key. It is also the only thing that makes the model's job tractable.
Cache is disposable; a stale entry costs one correction.

**Layer C — Composer (new, on-device).** `(Capture, CaptureContext, WorkspaceMirror) ->
ProposedIssue`. Guided generation, two independent calls so a failure in one does not
poison the other:

- *Route:* pick `teamId` and optional `projectId` from the mirror's real IDs. Enum-
  constrained — the model cannot emit an ID that does not exist. Refusal or timeout
  yields the user's default team and no project.
- *Title:* one line from the transcript. Reuses Cleanup's hard-won guards — the
  novel-word check adapted (a title may compress but not invent proper nouns absent
  from transcript and context), a length cap, first-sentence-only. Refusal or timeout
  yields no title.

The description is **deterministic template**, never model-written: the transcript
verbatim under the enrichment plan's fixed framing line, then the context bundle with
provenance. Same rule as the old exports — a cold receiver needs to know the quoted
block is speech.

**Layer X — The Linear exit (new, network).** OAuth PKCE, token in the Keychain,
GraphQL `issueCreate`. Issues created by an integration land in the team's Triage inbox
automatically (Linear's documented behavior), so the raw-ish artifact arrives in a
review queue by design. On success the card shows the issue identifier and links to it.

Seam discipline from the original plan holds: B knows nothing about destinations, C
knows nothing about acquisition, X knows nothing about how the proposal was composed.

## Auth

Linear supports **PKCE**, so a public open-source client ships no secret. Loopback
redirect (`http://localhost:<ephemeral>/oauth/callback`) — the standard native-app
pattern; a custom scheme is untested against Linear's redirect-URI validation and is
not worth the risk. Access token and refresh token in the Keychain, never in
`UserDefaults`, never in diagnostics. Disconnect revokes and clears. Scopes: `read`,
`write` only — the `app:assignable` / `app:mentionable` agent scopes are irrelevant
here and requesting them would trigger workspace-admin approval for nothing.

Settings gets a Linear page: connect/disconnect, default team, and a "what gets sent"
disclosure that is the same renderer the card uses.

## The card

Growth of the existing `CaptureCardBody`, which already has Copy. Saved captures only.

Send to Linear reveals a proposal inline — title (editable), team and project (both
pickers, pre-selected by the composer), and the context bundle collapsed behind a
disclosure showing exactly what will transmit. Send fires; the row then shows the issue
identifier. Nothing transmits before that press, and the compose pass is local, so a
user who never presses Send has still sent nothing.

Two-second rule: if the composer has not returned by the time the user looks, show the
deterministic fallback proposal and let the model fill it in underneath. The card must
never be a spinner.

## Sequencing

Each stage independently shippable, independently killable.

- **Stage 0 — `linear.new` spike (~1 hour, zero auth, zero risk).** Second button on
  the card opens a prefilled `linear.new` URL (documented params: `title`,
  `description`, `team`, `project`, `labels`). No OAuth, no GraphQL, no model.
  *Gate: does the button get pressed?* This is the hypothesis that killed enrichment
  twice, and it costs an hour to test. A quiet week is an answer, not a feature request.
- **Stage 1 — Auth + dumb send.** OAuth PKCE, Keychain, settings page, `issueCreate`
  with the raw transcript and no composition. Works on every plan. *Gate: does silent
  send beat the `linear.new` handoff enough to justify owning tokens?*
- **Stage 2 — Context returns.** `ContextCollector` and `CaptureContext` restored from
  the branch, wired into the description template, previewed on the card. Site and
  onboarding copy rewritten in the same pass — the privacy claim cannot lag the code.
  *Gate: founder audit — are the facts accurate, and do they make the resulting tickets
  atomic?*
- **Stage 3 — Composer.** Workspace mirror, then route and title. Preview and
  correction UI. *Gate: what fraction of proposals ship uncorrected? A route pick that
  is wrong more than occasionally should be demoted to a plain picker with no model.*
  **MEASURED 2026-08-01 (`YorickTests/IssueComposerEval`, 11 cases × 3 passes):
  routing 23/33, titles 15/15 — and the gate is passed on a stronger result than the
  headline number.** Every one of the ten misses was a DECLINE to a bare team; not one
  of thirty-three attempts filed a capture into the wrong project. That is the whole
  ballgame under a preview-before-send UI: under-routing costs one click in a picker
  already on screen, mis-routing buries a note somewhere nobody looks. The model stays
  on the route. Two cases fail systematically (context-only routing to the marketing
  site; a Yorick settings note whose vocabulary pulls elsewhere) and three are
  unstable across identical inputs — the honest read is 6/11 solid, 3/11 coin-flip,
  2/11 broken, with the residual landing safe. Also settled: context-only routing
  WORKS — "this number is wrong" with nothing but a pointed-at odds row routed
  correctly 3/3. That is the moment the feature exists for.
- **Stage 4 — Learn from corrections (only if Stage 3 earns it).** Every correction is
  a labeled example. Feeding recent corrections back as context for the route pick is
  cheap and stays entirely local. Explicitly not a classifier.

## Risks & kill criteria

- **The button may go unused.** Same risk that killed enrichment twice. Stage 0 tests
  it for an hour before anything is built.
- **The route pick may be unreliable.** Kill criterion is concrete: if corrections are
  routine at Stage 3, the model comes off the route and it becomes a plain picker with
  a remembered default. The feature survives without it; the ticket is still atomic.
- **Positioning debt.** Two published claims change at once ("nothing leaves your Mac"
  narrows, "never reads your screen" retires). Site, README, and onboarding are part of
  Stage 2's definition of done, not follow-up work. Shipping the code ahead of the copy
  would be the actual privacy failure.
- **Fragility returns with the context layer.** The 2026-07-29 removal noted that nearly
  every bug of the rebuild lived in evidence collection. Mitigation is that the fixtures
  came with it — the branch's collector is fixture-tested and reproducible from stored
  snapshots.
- **Scope creep to other destinations.** Notion, GitHub, Jira. The anti-Evernote test
  still gates: a second integration ships only if Linear's proves the shape, and never
  as a plugin architecture.

## Open questions

- Linear's redirect-URI validation for loopback ports — needs a live test against a real
  OAuth app registration before Stage 1 is estimated.
- Whether Foundation Models' guided generation handles a dynamic enum of workspace IDs
  cleanly, or whether the mirror needs to be flattened into a numbered list in the
  prompt. Measurable in an afternoon; sizes Stage 3.
- Whether a dictation (not just a saved capture) should be sendable. Currently scoped to
  saved captures only, matching the card's existing surface.
