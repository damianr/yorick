# Yorick

**Local-only macOS dictation with a safety net.**

Hold a hotkey (⌥Space) and talk. One rule:

- **In a text field** → your words are typed at the cursor.
- **Anywhere else** → they're saved, visibly marked, waiting for you.

Nothing you say gets lost — and none of it ever leaves your Mac.

## Privacy you can check

- No audio is ever uploaded. Transcription is Apple's on-device engine
  (zero download) or an optional local Whisper model.
- No account. No API key. No subscription. No analytics, no telemetry.
- Works offline. Airplane mode is a supported configuration.
- Two permissions only: Microphone (to hear you) and Accessibility
  (to type for you). No screen recording.
- Recordings are discarded after transcription; dictation history fades
  after 7 days, saved items after 30.

This repository is the proof of those claims. Read the source; run
Little Snitch; we insist.

## The details people ask about

- A small glass pill anchors to the focused field while you talk — it shows
  exactly where your words will land *before* you say them, rides the field
  as it grows, and offers Undo and on-device Cleanup after insertion.
- Guessed wrong? One keystroke (⌥⇧`) does the other thing: a typed
  dictation gets saved; a saved item gets typed wherever your cursor is now.
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
