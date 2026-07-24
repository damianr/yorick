#!/usr/bin/env bash
#
# Yorick release pipeline: build → sign (Developer ID, inside-out) → notarize
# → staple → DMG → notarize DMG → staple DMG → EdDSA-sign → appcast.
#
# Prereqs (one-time):
#   • Developer ID Application cert in your keychain (Xcode → Manage Certificates)
#   • notarytool profile:  xcrun notarytool store-credentials yorick-notary …
#   • Sparkle tools present at scripts/.sparkle-tools/bin (release.sh fetches them)
#   • EdDSA private key in your keychain (scripts already generated it; public
#     key is in Info.plist as SUPublicEDKey)
#
# Usage:
#   TEAM_ID=XXXXXXXXXX ./scripts/release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

# ── Config (override via env) ───────────────────────────────────────────────
APP_NAME="Yorick"
SCHEME="Yorick"
TEAM_ID="${TEAM_ID:?Set TEAM_ID to your Developer ID team (10 chars) — see: security find-identity -v -p codesigning}"
SIGN_ID="${SIGN_ID:-Developer ID Application}"      # codesign matches by name + team
NOTARY_PROFILE="${NOTARY_PROFILE:-yorick-notary}"
ENTITLEMENTS="Yorick/Resources/Yorick.entitlements"
REPO="damianr/yorick"
SPARKLE_BIN="scripts/.sparkle-tools/bin"
DERIVED="build/DerivedData"
DIST="dist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DERIVED/Build/Products/Release/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || \
           grep -A1 MARKETING_VERSION project.yml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
DL_PREFIX="https://github.com/$REPO/releases/download/v$VERSION/"

say() { printf '\n\033[1;35m▸ %s\033[0m\n' "$1"; }

# ── Preflight ───────────────────────────────────────────────────────────────
say "Preflight"
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
  || { echo "✗ No Developer ID Application certificate in keychain."; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "✗ notarytool profile '$NOTARY_PROFILE' not found. Run store-credentials."; exit 1; }
# Sparkle's CLI tools (sign_update, generate_appcast) ship inside the SPM
# artifact bundle. Resolve packages if needed and symlink them into place, so a
# fresh checkout (where scripts/.sparkle-tools is gitignored/absent) just works.
if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  xcodebuild -resolvePackageDependencies -project "$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" -derivedDataPath "$DERIVED" >/dev/null 2>&1 || true
  SPK_ARTIFACT="$(find "$DERIVED/SourcePackages/artifacts" -type d -path '*/Sparkle/bin' -print -quit 2>/dev/null || true)"
  if [ -n "$SPK_ARTIFACT" ]; then
    mkdir -p "$(dirname "$SPARKLE_BIN")"
    ln -sfn "$SPK_ARTIFACT" "$SPARKLE_BIN"
    echo "✓ linked Sparkle tools from SPM artifact bundle"
  fi
fi
[ -x "$SPARKLE_BIN/sign_update" ] || { echo "✗ Sparkle tools missing at $SPARKLE_BIN (SPM artifact not found — build once, then retry)"; exit 1; }
echo "✓ cert, notary profile, Sparkle tools present — releasing v$VERSION"

# ── 1. Build (Release) ──────────────────────────────────────────────────────
say "Building $APP_NAME v$VERSION"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" clean build >/dev/null
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DL_PREFIX="https://github.com/$REPO/releases/download/v$VERSION/"

# ── 2. Sign inside-out with Developer ID + hardened runtime ─────────────────
say "Signing (Developer ID, hardened runtime, inside-out)"
sign() { codesign --force --timestamp --options runtime -s "$SIGN_ID" "$@"; }

# whisper dylibs, then binaries
find "$APP/Contents/Resources/Whisper/lib" -name "*.dylib" -print0 | while IFS= read -r -d '' f; do sign "$f"; done
sign "$APP/Contents/Resources/Whisper/whisper-cli"
sign "$APP/Contents/Resources/Whisper/whisper-server"

# Sparkle: XPC services → Updater.app → Autoupdate → framework
SPK="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPK/Versions/B/XPCServices/Downloader.xpc"
sign "$SPK/Versions/B/XPCServices/Installer.xpc"
sign "$SPK/Versions/B/Updater.app"
sign "$SPK/Versions/B/Autoupdate"
sign "$SPK"

# Main app last, with entitlements — seals everything above
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS" -s "$SIGN_ID" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "✓ signature verifies"

# ── 3. Notarize + staple the app ────────────────────────────────────────────
say "Notarizing app (Apple scans all nested code)"
mkdir -p "$DIST"
ZIP="$DIST/$APP_NAME-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
echo "✓ app notarized + stapled"

# ── 4. Styled DMG → notarize + staple ───────────────────────────────────────
say "Building + notarizing DMG"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
VOL="$APP_NAME"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp scripts/assets/dmg-background.png "$STAGE/.background/background.png"

# Build a read-write DMG, dress the Finder window (background + icon layout),
# then compress it read-only. The .DS_Store Finder writes carries the styling.
RWDMG="$(mktemp -u).dmg"
hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RWDMG" >/dev/null
rm -rf "$STAGE"
hdiutil attach "$RWDMG" -readwrite -noverify -noautoopen >/dev/null
sleep 2
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {300, 160, 960, 590}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 104
    set text size of opts to 12
    set background picture of opts to file ".background:background.png"
    set position of item "$APP_NAME.app" of container window to {180, 190}
    set position of item "Applications" of container window to {480, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
sync
hdiutil detach "/Volumes/$VOL" >/dev/null
rm -f "$DMG"
hdiutil convert "$RWDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RWDMG"
codesign --force --timestamp -s "$SIGN_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | grep -q accepted \
  && echo "✓ DMG passes Gatekeeper"

# ── 5. EdDSA-sign + appcast ─────────────────────────────────────────────────
say "Signing update + generating appcast"
"$SPARKLE_BIN/generate_appcast" "$DIST" --download-url-prefix "$DL_PREFIX" >/dev/null
cp "$DIST/appcast.xml" appcast.xml
echo "✓ appcast.xml updated (enclosure → $DL_PREFIX$APP_NAME-$VERSION.dmg)"

# ── Done ────────────────────────────────────────────────────────────────────
say "Release v$VERSION ready"
cat <<DONE
  Artifact:  $DMG   (notarized + stapled)
  Appcast:   appcast.xml   (EdDSA-signed, points at the v$VERSION release asset)

  Ship it:
    1. gh release create v$VERSION "$DMG" --title "Yorick $VERSION" --notes "…"
    2. git add appcast.xml && git commit -m "release: v$VERSION" && git push
       (Sparkle reads appcast.xml from raw.githubusercontent.com/$REPO/main)
DONE
