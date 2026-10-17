# Yorick

Local-only macOS dictation with a safety net: hold ⌥Space and talk — in a text field your
words are typed; anywhere else they're saved. Your voice never leaves the Mac (no API keys,
no cloud; the only model surface is Apple's on-device Foundation Models for Cleanup; the
only network calls are the update check and anonymous counts, see TELEMETRY.md).

## Build

- `project.pbxproj` is generated — edit `project.yml`, then `xcodegen generate`
- Build: `xcodebuild -project Yorick.xcodeproj -scheme Yorick -configuration Release -derivedDataPath build/DerivedData build`
- Receipt/HUD diagnostics: `log show --process Yorick --last 5m | grep receipt`
- Admin-only settings (diagnostics): `defaults write com.heyyorick.Yorick adminMode -bool true`
