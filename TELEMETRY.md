# Telemetry

Yorick sends anonymous usage counts, never content — to its own endpoint,
not a third-party analytics service. This file is the complete contract:
every field, every network call. The entire client lives in one source file,
[`Yorick/Config/Telemetry.swift`](Yorick/Config/Telemetry.swift), and the
entire server is ~70 lines of public source (`api/ping.js` in the
heyyorick.com site repo). If a diff touches telemetry anywhere else, that's
a bug.

## The rules

- **No content, ever.** No transcripts, no audio, no window titles, no names
  of apps you dictated into. The payload is fixed keys with integer values;
  there is deliberately no code path that sends free-form text.
- **Anonymous by design.** The install id is a random UUID minted on your
  Mac, derived from nothing. The endpoint never stores where a request came
  from — no IP retention, no cookies, no cross-app anything.
- **One off switch.** Settings → Privacy → "Share anonymous usage counts."
  Default on; the payload is counts, the switch is one click, and onboarding
  discloses it in plain words — the same posture as the update check.
- **No SDK.** The sender is a plain HTTPS POST written in this repo. Nothing
  third-party rides along with it.

## The entire payload

At most a few times per hour (30-second debounce, plus once at launch),
Yorick posts that day's running totals:

| Field | Meaning |
| --- | --- |
| `id` | Random install UUID, minted on this Mac |
| `day` | The local calendar day the counts describe |
| `dictations` | Dictations typed into a field that day |
| `catches` | Utterances saved to the list that day |
| `launches` | App launches that day |
| `copies` | Saved items copied out that day |
| `panels` | Menu bar panel opens that day |
| `version` | App version |

Payloads are cumulative for the day and the server keeps the latest one, so
retries and repeats can never double-count.

## Every network call Yorick makes

1. **Update check** (Sparkle) — fetches the appcast on a schedule; every
   update is cryptographically signed. Off switch in Settings → Updates.
2. **Anonymous usage counts** — the payload above, to
   `heyyorick.com/api/ping`. Off switch in Settings → Privacy.
3. **Whisper model download** — only if you opt into the Whisper engine, one
   ~600 MB download.

That's the whole list. Your voice and your words never leave your Mac. Run
Little Snitch; read the source; we insist.
