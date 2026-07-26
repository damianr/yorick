# Enrichment — synthesized plan

Merged from three independently-written plans (three frontier models, same brief),
cross-judged blind against a fixed rubric. Base architecture is the winning plan;
grafts and cuts are noted where they matter. Nothing here has shipped.

## Design stance

**The exit drives the enrichment.** Old pipeline: capture → enrich → classify →
bucket → triage later. New pipeline: capture → you pick the exit → enrich *for
that exit*. "How much context is enough" has a concrete answer: enough to make
the artifact atomic at its destination, not more.

**The exit is the classification.** No kinds, no titles, no tags, no auto-filing,
ever. Choosing a destination carries strictly more information than any
classifier could recover afterward, and it's a decision the user makes anyway.

**Ship evidence, not conclusions.** The wedge audience's destination is usually
another LLM. "I don't like the way this looks" doesn't need its referent resolved
by Yorick — it needs the evidence attached so the receiving model can resolve it.
This removes the on-device model from the critical path entirely.

**Deterministic first; the model is a garnish.** Anything with a right answer is
a rule, not a prompt. The model appears only inside an exit's render, via guided
generation, with a mandatory deterministic fallback used on throw, refusal, or
timeout. An exit that cannot degrade to a deterministic render does not ship.
No unsolicited model output anywhere — no auto-titles (the user names the
artifact; a machine title is a small re-growth of classification).

**Anti-goals:** no Screen Recording or screenshots — not even on the roadmap; no
cloud; no background network; no categorization; no auto-apply; no new
permissions; no configuration on the default path; nothing that slows insertion.

## Architecture

Three independent layers plus exits. Each is useful alone; none blocks another.

**Layer A — Normalization (dictation correctness, not enrichment).** Pure
functions over (transcript, field profile), applied on the insert path before the
paste. No model, no I/O. Ships on `main`, never gated behind anything here.

**Layer B — Context bundle.** A versioned, `Codable` `CaptureContext` assembled
from Accessibility evidence, attached to `Capture` as one new optional field. Raw
fields with provenance — never a summary, never an inference. Every field
optional; absence is normal and never degrades the capture. Snapshots at trigger
and at release; the delta is itself evidence.

**Layer C — Exits.** An `Exit` protocol: title, availability check,
`render(Capture, CaptureContext) -> String`. Rendering is per-exit and
deterministic by default; this is where enrichment actually lives. The seam
matters: B knows nothing about destinations, C knows nothing about acquisition.

**Persistence & privacy.** Context lives on the existing ephemerality clock —
context is not a reason to keep things longer — and is excluded from diagnostic
logging by default (window titles, URLs, and selected text are more sensitive
than transcripts). Secure fields are never read, never transformed, never
logged. No wholesale field-value capture; selection and pointed-element text are
length-capped. The card previews exactly what any export will contain. Applied
normalization rules are recorded (rule IDs + before/after) so every
transformation is auditable and revertible. Renderers and the bundle schema are
versioned. All shaping/profiling/rendering is fixture-tested — reproducible from
stored snapshots, no live audio or victim apps required.

**Threading.** All AX acquisition is bounded: `AXUIElementSetMessagingTimeout`
per app element, a hard wall-clock budget for the whole bundle, partial results
on expiry, values read at acquisition (no `AXUIElement` refs held across the
utterance). Acquisition never delays transcription or insertion.

## Context acquisition

All Accessibility + `NSWorkspace`. (`CGWindowListCopyWindowInfo` is out —
`kCGWindowName` is Screen-Recording-gated since Catalina. The Apple Events
browser fallback is out — new TCC prompt, against zero-config.)

- **Rung 1 — free today:** app name, window title, and the `ElementContext`
  already gathered at trigger time (role, subrole, title, value, label, parent
  chain) — currently discarded after routing; persist it.
- **Rung 2 — selection:** `kAXSelectedTextAttribute` on the focused element.
  Likely the highest-value signal, but its coverage claim is *unverified* —
  rich editors (Pages, Mail compose) may return nil exactly where it matters.
  The spike measures this before anything depends on it.
- **Rung 3 — document identity:** `kAXURLAttribute` on the focused web area
  (browsers), `kAXDocumentAttribute` on the window (document apps). Coverage
  varies; window title is the fallback and is a hint, never a fact.
- **Rung 4 — pointed element only:** the element under the cursor plus a short
  ancestor chain, named attributes only. No radius walks, no general tree
  traversal (expensive in web areas, and "nearby siblings" was judged the
  likeliest-to-fail idea across all three plans).
- **Electron/Chromium:** trees are empty until `AXManualAccessibility` /
  `AXEnhancedUserInterface` is set (the codebase already does this for the
  caret — `enableAssistiveTree`). Keep it lazy and per-pid; it mutates another
  process and has caused resize-behavior jank.
- **Canvas apps (Figma, games):** app + window title is the honest ceiling. A
  sparse-but-true bundle beats a rich-but-inferred one.

**The stale-pointer rule.** Holding ⌥Space means hands on keyboard; the mouse is
often wherever you left it, so pointer-derived facts can't be trusted blindly.
Resolution — already in the repo: routing computes `pointerParked` from
`CGEventSource.secondsSinceLastEventType(.mouseMoved)` (AccessibilityCapture.swift,
focusedFallback path). Invert it for context: pointer-derived facts (rung 4, and
rung 2 when it came from the pointed element) enter the bundle only when the
pointer was recently, deliberately moved; a parked pointer yields a focus/app
level bundle. No new gesture, no modifier, zero config.

## Output shaping & normalization

- Spoken email/URL runs → symbols (`at`/`dot`/`dash`/`underscore`/`plus` inside
  address-shaped runs only), everywhere — it's a transcript pattern, not a field
  feature. Validation is structural (label shape + curated TLD list), NOT
  `NSDataDetector` as originally proposed: the detector's TLD table lags
  reality (measured: it rejects `linear.app`), so as a gate it silently blocks
  exactly the modern TLDs this user dictates.
- Search fields (role/subrole already available) → strip trailing period.
- URL fields → no spaces, no sentence casing.
- Ambiguity → emit the words as spoken. Under-normalizing beats inventing (the
  same trade Cleanup settled). Field role adjusts confidence; it never gates a
  rule alone.

## The card

Growth of the existing saved-capture toast (`HUDContentView.swift`,
`captureSavedToast`), not a new surface. Saved captures only — after a dictation,
confirmation is the words appearing. Non-activating panel, never steals focus,
hover pauses dismissal (the skull's pattern), newer capture replaces older — no
queue, no badges. Dismiss always means "it's in the list; later."

Exits, in order: **Copy** → **Copy with Context** (paste-ready markdown:
transcript + evidence with provenance — the "Copy for Claude" shape, aimed at
the coding-agent workflow) → **Share** (`NSSharingServicePicker` + user-chosen
Shortcuts: satisfies "send to integrations" with zero network code, zero tokens,
and the user naming the destination). Direct integrations (Linear, Notion) are
**cut from this plan** — a user-initiated network exit reopens the checkable
"no network calls" positioning commitment, and that gets decided deliberately,
later, only if Share usage proves demand.

## Sequencing

- **Stage 0 — Layer A on `main`.** Normalization rules + fixtures. Unambiguously
  good alone; waits on nothing.
- **Spike — 1 day, before plumbing.** Measure real AX fact coverage (selection,
  URL, document, pointed element, Electron enablement jank) across the actual
  daily app set: Chrome, Terminal, VS Code, Linear, Slack, Mail. This is the
  plan's highest-variance input; the results size rungs 2–4 or kill them.
- **Stage 1 — Card v1.** Toast grows into the card: transcript + the rung-1
  context line (app · window) + Copy + Dismiss. *Gate:* the card gets used.
  (The context line is deliberately included so a quiet week indicts the
  timing hypothesis, not the missing-context one — a fully raw card would
  confound the two.)
- **Stage 2 — Layer B.** Full bundle: dual snapshots, pointer-freshness gating,
  spike-validated rungs; persisted, visible in the saved-list detail; Copy with
  Context appears. *Gate:* founder audit over weeks — are the facts accurate,
  and would they have made captures atomic?
- **Stage 3 — Layer C.** Exit protocol; Copy-with-Context formalized as a
  render; Share/Shortcuts. *Gate:* which exits get used, and where Copy output
  actually gets pasted.
- **Stage 4 — Model garnish**, only where a deterministic render is demonstrably
  poor, inside `render`, guided, fallback mandatory, fails silent.

Each stage is independently shippable and independently killable; each layer
survives the death of the layer above it.

## Risks & kill criteria

- **The hypothesis may be wrong:** the card may go unused as enrichment did.
  Stage 1 finds out cheaply; a quiet week is an answer, not a feature request.
- **AX may be too thin:** if the spike shows selection/URL coverage is poor in
  the daily apps, stage 2 shrinks to focus-level context — still useful,
  smaller product.
- **Escalation blast radius:** widening `AXManualAccessibility` use widens a
  side effect on other processes; keep lazy, per-pid, and revisit if jank
  reports appear.
- **Positioning drift:** every exit makes Yorick look more like a capture tool.
  The anti-Evernote test guards each addition; Share-not-integrations guards
  the network promise.
- **Context sensitivity:** same ephemerality clock, diagnostics-excluded,
  preview-before-export — non-negotiable from stage 2 onward.
