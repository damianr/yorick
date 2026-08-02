# Yorick

**Local-only macOS dictation with a safety net.**

Hold a hotkey (⌥Space) and talk. One rule:

- **In a text field** → your words are typed at the cursor.
- **Anywhere else** → they're saved, visibly marked, waiting for you.

Nothing you say gets lost — and nothing leaves your Mac unless you send it.

## Privacy you can check

- No audio is ever uploaded. Transcription is Apple's on-device engine
  (zero download) or an optional local Whisper model.
- No account. No API key. No subscription.
- Works offline. Airplane mode is a supported configuration.
- Two permissions on the default path: Microphone (to hear you) and
  Accessibility (to type for you). Screen Recording is optional and asked
  for only if you use the screenshot button in the Linear integration.
- Recordings are discarded after transcription; dictation history fades
  after 7 days, saved items after 30.
- The only routine network calls are the signed update check and anonymous
  usage counts — "a dictation happened," never what it said. Every event is
  enumerated in [TELEMETRY.md](TELEMETRY.md), the whole analytics surface is
  one auditable source file, and the off switch is in Settings.

**The one exception, stated plainly.** There is an optional Linear
integration, off until you connect it. With it on, a saved capture gets a
Send button that files it as a Linear issue — and only then does anything
you said leave this machine. You see the whole payload before it goes:
title, team, project, and every line of context. Nothing is sent until you
press the button. Turn it off, or never turn it on, and Yorick makes no
network call carrying anything you said.

While that integration is on, captures also record accessibility context —
what was selected, the page or document open, what you pointed at — so an
issue makes sense to someone who wasn't sitting there. That includes
dictations, so a capture is still filable when it typed into a field you
didn't mean to be in. It stays on the same expiry clock as everything else,
and it goes nowhere until you send. With the integration off, none of it is
read at all.

The integration also puts a camera button on the recording pill when you're
NOT in a text field: drag a region while you're talking and the crop rides
along with the capture. (In a field it's deliberately absent — clicking it
would blur the field you're dictating into. Attach one from the capture's
page instead.) That one needs Screen Recording, asked for the first time you
use it and never otherwise — nothing else in Yorick takes a screenshot, and
the permission is not part of setup.

This repository is the proof of those claims. Read the source; run
Little Snitch; we insist.

## The details people ask about

- A small glass pill anchors to the focused field while you talk — it shows
  exactly where your words will land *before* you say them, and rides the
  field as it grows.
- Optional on-device Cleanup runs *before* the paste, so the field only ever
  shows final text. If it can't run, your words are typed exactly as spoken,
  and the list always keeps the original.
- Your clipboard is borrowed, not taken: it's restored the moment it's safe,
  including if you press ⌘V mid-paste.
- The saved list is deliberately plain: full raw text, where and when you
  said it, click to copy. No folders, no tags, nothing to organize or tend.

## Status

Early, and moving fast. Built as its maker's daily driver; notarized
downloads and a website are on the way. Until then, build from source:

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Yorick.xcodeproj -scheme Yorick -configuration Release build
```

Requires macOS 14+ (the zero-download engine and on-device Cleanup are
macOS 26 features). Capabilities grow only when users ask — open an issue
and ask.

## License

MIT — see [LICENSE](LICENSE). Third-party components are listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). The Yorick name and
icon are not covered by the code license.
