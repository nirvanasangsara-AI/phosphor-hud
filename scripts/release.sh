#!/usr/bin/env bash
# Builds a release zip of Phosphor.app and prints its sha256 (for the Homebrew cask).
#
#   ./scripts/release.sh 0.2.0
#
# Signing is optional and never invented: set PHOSPHOR_SIGN_IDENTITY to a "Developer ID Application: …"
# identity that exists in your keychain (see `security find-identity -v -p codesigning`). Without it the
# app stays ad-hoc signed, as build-app.sh leaves it. Notarization: see docs/RELEASE.md.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version>}"
export VERSION

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

ZIP="dist/Phosphor-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${PHOSPHOR_NOTARY_PROFILE:-}" ]]; then
  echo "• notarizing with keychain profile \$PHOSPHOR_NOTARY_PROFILE"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PHOSPHOR_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
fi

shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "✓ $ZIP — put the sha256 above into packaging/homebrew/phosphor.rb"
