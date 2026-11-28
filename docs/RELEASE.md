# Releasing Phosphor

The version people see is the `VERSION` file at the repo root. `scripts/build-app.sh` reads it for `CFBundleShortVersionString` on every local build and in CI. `CFBundleVersion` is the git commit count (`git rev-list --count HEAD`), so it goes up even when the marketing version stays put. The menu and the bottom of the usage panel show `Phosphor 0.2.2`.

## Publish

1. Bump `VERSION` (for example from `0.2.1` to `0.2.2`) and commit that change on `main`.
2. Push a tag that matches the file exactly: `git tag v0.2.2 && git push origin v0.2.2`.
3. The release workflow (macOS 15) builds a universal app, ad-hoc signs it with `codesign -s -`, packs `Phosphor.dmg` (volume name Phosphor, app plus an Applications symlink) and `Phosphor.zip`, and attaches both to the GitHub Release for that tag.
4. The workflow fails if the tag and `VERSION` do not match.

Running the workflow by hand (Actions → release → Run workflow) uploads the DMG and zip as artifacts. It does not publish a Release.

`./scripts/release.sh` does the same packaging on your Mac: tests, app, DMG, zip, and sha256 files. It reads `VERSION`. Passing a different number is an error. `UNIVERSAL=1` builds arm64 + x86_64 and needs full Xcode selected with `xcode-select`.

Copy `packaging/homebrew/phosphor.rb` into a tap after the Release exists. Set `version` to the `VERSION` file and `sha256` to `dist/Phosphor.dmg.sha256`.

## Signing and notarization (optional)

Local `./scripts/build-app.sh` uses a stable signing identity when one is available (`PHOSPHOR_SIGN_IDENTITY`, an existing Developer ID / Apple Development certificate, or a reusable self-signed "Phosphor Local" identity) so Keychain ACLs survive rebuilds. CI and machines with no local cert fall back to an ad-hoc signature. The release workflow always ad-hoc signs before packaging, then replaces that signature only when the Developer ID secrets below are present.

- Sign locally: `PHOSPHOR_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/release.sh`
  (list yours with `security find-identity -v -p codesigning`).
- Notarize locally: store credentials once with
  `xcrun notarytool store-credentials phosphor-notary --apple-id you@example.com --team-id TEAMID`
  (it prompts for an app-specific password), then add `PHOSPHOR_NOTARY_PROFILE=phosphor-notary`.
  The script submits the app, staples it, rebuilds the DMG and zip, then notarizes and staples the DMG.
- Without both, the first launch is a right-click → Open, or System Settings → Privacy & Security → Open Anyway on macOS 15+.

### GitHub Actions secrets

Developer ID signing and notarization in the release workflow are skipped when these secrets are absent:

| Secret | What |
| --- | --- |
| `APPLE_ID` | Apple ID email |
| `TEAM_ID` | Apple Developer Team ID |
| `APPLE_CERTIFICATE` | the cert: a Developer ID Application `.p12`, base64-encoded |
| `APPLE_CERTIFICATE_PASSWORD` | password for that `.p12` |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password for `notarytool` |

Signing runs when `APPLE_ID`, `TEAM_ID`, and `APPLE_CERTIFICATE` are all set (and the `.p12` password is set). Notarization also needs `APPLE_APP_SPECIFIC_PASSWORD`. If that password is missing, the app stays Developer ID signed and is not notarized.

## Checklist

- `swift test` green, `./scripts/build-app.sh --run` launches, and the menu and the usage panel say `Phosphor` plus the `VERSION` file.
- No secrets in the repo: the app reads logins from the official CLIs at runtime only.
- Screenshots in `docs/screenshots` come from `--demo --stage` (no real account data, no third-party logos).
