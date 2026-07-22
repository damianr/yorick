# Releasing Yorick

Yorick ships as a notarized DMG downloaded from GitHub Releases, with in-app
auto-updates via [Sparkle](https://sparkle-project.org). One command builds,
signs, notarizes, and produces the signed appcast.

## One-time setup

1. **Developer ID certificate** — Xcode → Settings → Accounts → your individual
   team → Manage Certificates → **+** → **Developer ID Application**. Confirm:
   ```sh
   security find-identity -v -p codesigning   # expect: Developer ID Application: … (TEAMID)
   ```

2. **Notarization credentials** — create an app-specific password at
   account.apple.com → Sign-In and Security, then:
   ```sh
   xcrun notarytool store-credentials yorick-notary \
     --apple-id "you@example.com" --team-id "TEAMID" --password "xxxx-xxxx-xxxx-xxxx"
   ```

3. **EdDSA update-signing key** — already generated; the **private key lives in
   your login keychain** and the public key is in `Info.plist` (`SUPublicEDKey`).
   ⚠️ Back this key up (Keychain Access → search "Sparkle" / "ed25519") and never
   commit it. Losing it means no user can auto-update to a build signed with a new
   key — they'd have to re-download manually. To export a backup:
   `scripts/.sparkle-tools/bin/generate_keys -x sparkle_private_key.txt` (store it
   somewhere safe offline, then delete the file).

## Cutting a release

1. Bump the version in `project.yml` (`MARKETING_VERSION`, and
   `CURRENT_PROJECT_VERSION` — Sparkle compares the latter), then `xcodegen generate`.

2. Run the pipeline:
   ```sh
   TEAM_ID=YOURTEAMID ./scripts/release.sh
   ```
   This builds Release, signs everything inside-out with Developer ID + hardened
   runtime (the whisper binaries/dylibs and Sparkle's nested helpers all need their
   own signatures), notarizes and staples both the app and the DMG, then
   EdDSA-signs the update and regenerates `appcast.xml`.

3. Publish (the script prints these):
   ```sh
   gh release create vX.Y.Z dist/Yorick-X.Y.Z.dmg --title "Yorick X.Y.Z" --notes "…"
   git add appcast.xml && git commit -m "release: vX.Y.Z" && git push
   ```
   Sparkle reads `appcast.xml` from `raw.githubusercontent.com/damianr/yorick/main`,
   whose enclosure URL points at the release asset you just uploaded.

## How the signing chain stays honest

- **Developer ID + notarization** is what lets a stranger's Mac open Yorick without
  a Gatekeeper block. It's mandatory because the App Sandbox forbids the
  Accessibility API Yorick needs — so the Mac App Store isn't an option.
- **Hardened runtime** is required for notarization; `disable-library-validation`
  in the entitlements is what lets the hardened main app load the bundled whisper
  dylibs (same-team signature, so it's safe).
- **EdDSA-signed updates** mean a tampered download is rejected even if GitHub or
  the network were compromised — the update installs only if it matches the private
  key that pairs with `SUPublicEDKey`. The only update-related network call is
  fetching the signed appcast, keeping the "nothing leaves your Mac" claim intact.

## Notes

- The appcast currently carries only the latest release. Sparkle offers an update
  whenever the newest item's `CURRENT_PROJECT_VERSION` exceeds the running build,
  so a single-entry appcast is fully functional (delta updates, which need past
  builds retained, are not enabled).
- `scripts/.sparkle-tools/` and `dist/` are gitignored — tool binaries and build
  artifacts don't belong in the repo.
- The feed URL and download prefix currently point at GitHub. When the marketing
  site is live, both can move to the real domain (edit `SUFeedURL` in Info.plist
  and `REPO`/`DL_PREFIX` in `scripts/release.sh`).
