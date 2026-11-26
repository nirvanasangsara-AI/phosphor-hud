# Releasing Phosphor

1. Update `VERSION` default in `scripts/build-app.sh` if you like, and the README changelog.
2. `./scripts/release.sh 0.2.0` — runs `swift test`, builds `dist/Phosphor.app`, zips it to
   `dist/Phosphor-0.2.0.zip` and prints the sha256 (also saved next to the zip).
   - `UNIVERSAL=1` builds arm64 + x86_64 (needs full Xcode selected with `xcode-select`).
3. Create the GitHub release `v0.2.0` and upload the zip.
4. Copy `packaging/homebrew/phosphor.rb` into your tap, set `version`, `sha256`, and replace `OWNER`.

## Signing and notarization (optional)

Phosphor ships ad-hoc signed until a real Apple Developer ID is available. Nothing in the scripts
assumes or fakes an identity.

- Sign: `PHOSPHOR_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/release.sh 0.2.0`
  (list yours with `security find-identity -v -p codesigning`).
- Notarize: store credentials once with
  `xcrun notarytool store-credentials phosphor-notary --apple-id you@example.com --team-id TEAMID`
  (it prompts for an app-specific password), then add `PHOSPHOR_NOTARY_PROFILE=phosphor-notary`.
  The script submits, waits, staples and re-zips.
- Without both, users open the first launch with right-click → Open, or
  `xattr -dr com.apple.quarantine /Applications/Phosphor.app`.

## Checklist

- `swift test` green, `./scripts/build-app.sh --run` launches, HUD shows rows.
- No secrets in the repo: the app reads logins from the official CLIs at runtime only.
- Screenshots in `docs/screenshots` come from `--demo --stage` (no real account data, no third-party logos).
