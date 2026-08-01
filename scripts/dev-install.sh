#!/usr/bin/env bash
#
# Yorick dev install: build → sign with Developer ID → replace /Applications.
#
# WHY THIS EXISTS. The Accessibility grant is the whole product — without it
# there is no field detection, so the pill never anchors and every dictation
# saves instead of typing. macOS keys that grant on bundle id PLUS the code
# signing requirement, and a plain `xcodebuild` produces an Apple Development
# signature (team JD2ZUW2N95) while the installed app carries Developer ID
# (team QFVQCASSH2). Same bundle id, different requirement: System Settings
# shows ONE "Yorick" row, you toggle it, and the build you are actually
# running still reads AXIsProcessTrusted() == false. You cannot fix that by
# clicking harder, which is exactly how it wastes an afternoon.
#
# So the dev build gets the SAME identity as the release and lands at the SAME
# path. One row, one grant, nothing to re-approve when you switch branches —
# and the branch becomes your daily driver, which is the only way to find out
# whether you actually reach for a feature.
#
# Not notarized, deliberately: Gatekeeper gates quarantined DOWNLOADS, and a
# locally built app has no quarantine bit. Releases still go through
# scripts/release.sh, which notarizes and staples.
#
# Rollback is a drag-install from dist/Yorick-0.2.3.dmg (or any older dmg).
#
# Usage:  ./scripts/dev-install.sh
set -euo pipefail

APP_NAME="Yorick"
SCHEME="Yorick"
DERIVED="build/DerivedData"
SIGN_ID="${SIGN_ID:-Developer ID Application}"
ENTITLEMENTS="Yorick/Resources/Yorick.entitlements"
TARGET="/Applications/$APP_NAME.app"

cd "$(dirname "$0")/.."

say() { printf "\n\033[1m▸ %s\033[0m\n" "$*"; }

security find-identity -v -p codesigning | grep -q "Developer ID Application" || {
  echo "✗ No Developer ID Application certificate in the keychain."
  echo "  Without it this script would install an Apple Development signature,"
  echo "  which is the exact TCC mismatch it exists to avoid."
  exit 1
}

say "Building $APP_NAME (Release)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" build >/dev/null
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

# Inside-out, same order as release.sh — nested code first, main app last, so
# the outer signature seals everything beneath it.
say "Signing (Developer ID, hardened runtime, inside-out)"
sign() { codesign --force --timestamp --options runtime -s "$SIGN_ID" "$@"; }

find "$APP/Contents/Resources/Whisper/lib" -name "*.dylib" -print0 2>/dev/null |
  while IFS= read -r -d '' f; do sign "$f"; done
[ -e "$APP/Contents/Resources/Whisper/whisper-cli" ] && sign "$APP/Contents/Resources/Whisper/whisper-cli"
[ -e "$APP/Contents/Resources/Whisper/whisper-server" ] && sign "$APP/Contents/Resources/Whisper/whisper-server"

SPK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPK" ]; then
  sign "$SPK/Versions/B/XPCServices/Downloader.xpc"
  sign "$SPK/Versions/B/XPCServices/Installer.xpc"
  sign "$SPK/Versions/B/Updater.app"
  sign "$SPK/Versions/B/Autoupdate"
  sign "$SPK"
fi

codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" -s "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"

TEAM="$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
echo "✓ signed, team $TEAM"

say "Installing to $TARGET"
osascript -e 'quit app "Yorick"' 2>/dev/null || true
# Give the app a moment to release its status item and unregister the hotkey.
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Yorick >/dev/null || break; sleep 0.3; done
pkill -x Yorick 2>/dev/null || true

rm -rf "$TARGET"
ditto "$APP" "$TARGET"
open "$TARGET"

cat <<EOF

✓ $APP_NAME $VERSION installed and running (team $TEAM)

If Accessibility still misbehaves, the old grant is stale rather than
mismatched — clear it and re-approve ONCE:

  tccutil reset Accessibility com.heyyorick.Yorick

EOF
