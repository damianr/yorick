# Yorick

**Local-only dictation for macOS.**

Hold ⌥Space, talk, let go. Your words are typed at the cursor.

Not in a text field? Nothing is lost. What you said is saved to a list in the
menu bar, one Copy click from wherever you meant it to go.

Your voice and your words never leave your Mac.

## Privacy you can check

- Transcription runs on your Mac: Apple's on-device engine by default (no
  download), or an optional local Whisper model.
- No account. No API key. No subscription.
- Works offline.
- Two permissions: Microphone, to hear you, and Accessibility, to type for you
  and to tell whether a text field is focused. Yorick never reads what's on
  your screen, and it never asks for Screen Recording.
- Audio is deleted as soon as it's transcribed. Dictations leave the list
  after 7 days, saved items after 30.
- The only routine network calls are the signed update check and anonymous
  usage counts ("a dictation happened," never what it said). Every call is
  listed in [TELEMETRY.md](TELEMETRY.md), and the off switch is in Settings.

This repository is the proof. Read the source; run Little Snitch.

## The details people ask about

- **You see where your words will land.** A small pill sits at the caret
  while you talk, in apps that report where the caret is. Elsewhere it sits
  at the bottom of the screen.
- **Your clipboard is left alone.** Yorick pastes through the clipboard and
  puts yours back right after, so a ⌘V of your own still pastes what you
  copied. Clipboard managers are told to skip the transcript.
- **Optional Cleanup.** Turn on "Clean up dictation before it types" and
  filler words are removed on-device before anything is typed. It never adds
  a word you didn't say, and the list always keeps exactly what you said.
  Requires Apple Intelligence on macOS 26.
- **"Note to self…"** Start with that (or "reminder," "idea," "bug") and
  Yorick saves it to the list even with a field focused.
- **The saved list is plain.** Your words, the app you said them in, and a
  Copy button. Nothing to organize.

## Install

Download the latest notarized build from
[GitHub Releases](https://github.com/damianr/yorick/releases/latest) or
[heyyorick.com](https://heyyorick.com). Updates arrive through the app.

Requires macOS 14 or later. The no-download engine and Cleanup need macOS 26;
on earlier versions Yorick uses the Whisper engine (a one-time ~600 MB
download).

To build from source:

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Yorick.xcodeproj -scheme Yorick -configuration Release build
```

## Status

Yorick is its maker's daily driver, free and maintained. Bug reports are
welcome in [Issues](https://github.com/damianr/yorick/issues).

## License

MIT, see [LICENSE](LICENSE). Third-party components are listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). The Yorick name and
icon are not covered by the code license.
