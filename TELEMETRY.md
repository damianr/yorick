# Telemetry

Yorick sends anonymous usage counts, never content. This file is the complete
list — every event, every payload key, every network call the app makes. The
entire analytics surface lives in one source file,
[`Yorick/Config/Telemetry.swift`](Yorick/Config/Telemetry.swift); if a diff
touches telemetry anywhere else, that's a bug.

## The rules

- **No content, ever.** No transcripts, no audio, no window titles, no names
  of apps you dictated into. Payloads are fixed keys with enumerable values;
  there is deliberately no code path that sends free-form text.
- **Anonymous by design.** Yorick passes no user identifier. The service
  (TelemetryDeck) derives one client-side and hashes it, so counts can't be
  tied to a person or joined across apps. No cookies, no ad identifiers, no
  cross-app tracking.
- **One off switch.** Settings → Privacy → "Share anonymous usage counts."
  Default on; the payload is counts, the switch is one click, and onboarding
  discloses it in plain words — the same posture as the update check.
- **Source builds send nothing.** The TelemetryDeck app id in
  `Telemetry.swift` ships empty in the repo; without it, telemetry never
  initializes.

## Every event

| Event | Payload | When |
| --- | --- | --- |
| `App.launched` | — | The app starts. |
| `Dictation.typed` | `engine`: `appleAnalyzer` \| `apple` \| `whisper` | A dictation was typed into a field. |
| `Catch.saved` | — | Words spoken outside a field were saved to the list. |
| `Capture.copied` | — | A saved item was copied out, from the list or the card. |
| `Cleanup.toggled` | `enabled`: `true` \| `false` | The pre-insert Cleanup setting flipped. |
| `Onboarding.stepReached` | `step`: `welcome` \| `setup` \| `tryIt` \| `done` | An onboarding step appeared (once per step). |
| `Onboarding.completed` | — | Onboarding finished. |
| `Panel.opened` | — | The menu bar panel was opened. |

Alongside each event, the TelemetryDeck SDK includes its standard metadata:
app version, macOS version, device model, locale, and the salted hash it uses
as the anonymous session marker. Nothing else. The SDK is open source:
[TelemetryDeck/SwiftSDK](https://github.com/TelemetryDeck/SwiftSDK).

## Every network call Yorick makes

1. **Update check** (Sparkle) — fetches the appcast on a schedule; every
   update is cryptographically signed. Off switch in Settings → Updates.
2. **Anonymous usage counts** (TelemetryDeck, the events above) — off switch
   in Settings → Privacy.
3. **Whisper model download** — only if you opt into the Whisper engine, one
   ~600 MB download.

That's the whole list. Your voice and your words never leave your Mac. Run
Little Snitch; read the source; we insist.
