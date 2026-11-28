#!/usr/bin/env bash
# Builds dist/Phosphor.dmg and dist/Phosphor.zip and prints their sha256.
#
#   ./scripts/release.sh
#   ./scripts/release.sh 0.2.1     # optional; must match the VERSION file
#
# The version is the VERSION file. Signing is optional and never invented: set
# PHOSPHOR_SIGN_IDENTITY to a "Developer ID Application: …" identity that exists
# in your keychain (see `security find-identity -v -p codesigning`). Without it
# the app stays ad-hoc signed, as build-app.sh leaves it. Notarization: see docs/RELEASE.md.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ $# -ge 1 && "$1" != "$VERSION" ]]; then
  echo "error: $1 does not match VERSION ($VERSION). Edit the VERSION file, then run this script." >&2
  exit 1
fi

swift test
UNIVERSAL="${UNIVERSAL:-0}" ./scripts/build-app.sh

APP="dist/Phosphor.app"
if [[ -n "${PHOSPHOR_SIGN_IDENTITY:-}" ]]; then
  echo "• signing with \$PHOSPHOR_SIGN_IDENTITY (hardened runtime)"
  codesign --force --deep --options runtime --timestamp --sign "$PHOSPHOR_SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "• PHOSPHOR_SIGN_IDENTITY not set: keeping the ad-hoc signature (users must right-click → Open)"
fi

# Notarize the app before packing it, so the staple is inside the DMG and the zip.
if [[ -n "${PHOSPHOR_NOTARY_PROFILE:-}" ]]; then
  echo "• notarizing the app with keychain profile \$PHOSPHOR_NOTARY_PROFILE"
  TMPZIP="$(mktemp "${TMPDIR:-/tmp}/phosphor-notarize.XXXXXX")"
  rm -f "$TMPZIP"
  ditto -c -k --keepParent "$APP" "$TMPZIP.zip"
  xcrun notarytool submit "$TMPZIP.zip" --keychain-profile "$PHOSPHOR_NOTARY_PROFILE" --wait
  rm -f "$TMPZIP.zip"
  xcrun stapler staple "$APP"
fi

./scripts/make-dmg.sh

ZIP="dist/Phosphor.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${PHOSPHOR_NOTARY_PROFILE:-}" ]]; then
  echo "• notarizing Phosphor.dmg"
  xcrun notarytool submit "dist/Phosphor.dmg" --keychain-profile "$PHOSPHOR_NOTARY_PROFILE" --wait
  xcrun stapler staple "dist/Phosphor.dmg"
fi

shasum -a 256 "dist/Phosphor.dmg" | tee "dist/Phosphor.dmg.sha256"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "✓ dist/Phosphor.dmg and $ZIP — put the dmg sha256 into packaging/homebrew/phosphor.rb"
