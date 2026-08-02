# Proposed reversal: capture is the product, dictation is the extra

**Status: PROPOSED, not true yet.** Deliberately living in the repo rather than
in the SOT, because the SOT holds durable truth and this is a bet with a
stated test. If the test passes, reconcile folds it in and this file is
deleted. If it fails, this file is the record of why it was tried.

Proposed 2026-08-02. Decision due **2026-08-16**.

## What it reverses

The first founding insight in the SOT:

> **Dictation is the product.** Yorick's earlier incarnations paired dictation
> with AI-enriched capture […]. Its most motivated possible user — the founder,
> using it all day — reached for dictation constantly and the enriched capture
> almost never. The product followed the usage.

The proposal inverts it: Yorick is a **local-first ticket context builder** —
you point at the thing, say what's wrong, and a filed issue carries the
evidence of what you were looking at. Dictation becomes the quiet extra that
happens to be excellent, not the headline.

## Why now

**The dictation market was commoditized this year, by the SOT's own reckoning.**
Free system-wide voice in the Gemini Mac app made the mechanic — hold a key,
talk anywhere, clean text at the cursor — table stakes, given away by Google.
The SOT already records the conclusion: *"differentiating on the gesture is
dead."* What remains for a dictation product is privacy and the catch, both
real, neither a reason someone switches tools.

**The capture mechanic has no equivalent.** Nobody ships "point at a thing
while talking and get a ticket carrying what you pointed at." The pieces are
specific and hard-won: a pointer sweep sampled while you speak, headings found
by walking up the screen rather than the tree, OCR over a region you framed
yourself, titles assembled from evidence rather than written. The local-only
constraint is what makes it hard to copy — a cloud competitor needs screen
access AND a server to send it to, which is the exact trade Yorick doesn't
have to make.

**The jobs differ in kind.** Dictation is a preference; people manage by
typing. Filing the thing you just noticed is friction people actively resent.
The second is a better thing to be the answer to.

## Why this is not simply attempt three

Capture has been built and cut twice. The SOT's most heavily recorded finding
is that both died of non-use. The distinction that makes this attempt
different, stated so it can be judged rather than assumed:

- **v1 classified for STORAGE** — kinds, tags, titles, a pile to triage later.
  Died because the pile was the product and nobody empties a pile.
- **v2 shipped EVIDENCE for a later reader** — verbatim context, copy with
  context, no destination. Died because "it lives in a weird space" and the
  value was unexplainable.
- **v3 has an EXIT.** The artifact leaves. It becomes an issue in the tracker
  you already work in, or a ticket on the clipboard for an agent. Nothing is
  stored to be dealt with later; the capture is finished when it lands.

That is a real structural difference, not a rationalization. It is also
exactly what the anti-Evernote test asks for: does this help an artifact
leave, or make staying comfortable?

## The test

**Two weeks of founder use, decided on 2026-08-16.**

Passes if:

1. **Send or Copy ticket gets used on most days.** Not volume — frequency. A
   feature reached for on 10 of 14 days is a habit; one used in a burst and
   then not is the same curve enrichment traced twice.
2. **Filed tickets survive.** They get worked, not deleted or rewritten from
   scratch. A ticket that has to be rebuilt by hand is a demo, not a tool.
3. **Routing needs correcting occasionally, not routinely.** If the project
   picker is touched on most sends, the magic isn't there and the pitch is
   overselling.

Fails if:

- The button goes quiet after the first week — the enrichment curve, third
  time.
- Tickets need rewriting to be useful.
- The landing page, reframed around capture, draws no more interest than the
  dictation framing did. (Cheap, parallel, and worth shipping immediately —
  it tests demand without touching the product.)

## What changes if it passes

Recorded now so the cost is visible before the decision, not after:

- **Onboarding gains the capture try-it back** (retired 2026-07-29 with the
  context layer) and a Linear connect step. The four-step flow becomes five.
  Skippable, because Copy ticket needs no integration — but present, because a
  product whose point is filing tickets cannot hide the filing.
- **"Two permissions only" stops being a headline.** Screen Recording moves
  from optional extra toward core, and the privacy claim has to be stated as
  what it is: nothing leaves unless you send it.
- **The hero changes** from "hold a key and talk" to the capture mechanic, and
  dictation moves below the fold as the thing that makes capture fast.
- **Wedge audience narrows and sharpens**: people who drive coding agents by
  voice becomes people who file tickets about what they're looking at — which
  includes designers and PMs, not only engineers.

## What would make it wrong

- Usage says otherwise. This is the whole point of the test.
- The quality bar isn't reachable. As of today: routing 82% on a corpus
  written for the purpose, titles validated against one real capture, OCR
  never run on a real crop, upload confirmed once, multi-workspace untested.
  Leading a product with its least-proven half is how you ship something
  embarrassing.
- Dictation turns out to be what retains people even if capture is what
  attracts them — in which case the honest framing is two products in one app,
  which the SOT has already rejected once for good reasons.
