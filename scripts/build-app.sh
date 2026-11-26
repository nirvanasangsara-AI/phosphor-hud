#!/usr/bin/env bash
# Builds dist/Phosphor.app. Usage:
#   ./scripts/build-app.sh            # native arch
#   UNIVERSAL=1 ./scripts/build-app.sh  # arm64 + x86_64 (needs full Xcode)
#   ./scripts/build-app.sh --run      # build and launch
#
# Signing prefers a stable identity so Keychain ACLs survive rebuilds:
#   1. $PHOSPHOR_SIGN_IDENTITY, if set
#   2. an existing Developer ID Application, Apple Development, or "Phosphor Local" identity
#   3. a newly created self-signed "Phosphor Local" identity (interactive machines only)
#   4. ad-hoc (`codesign --sign -`) in CI, or when no local cert can be used
set -euo pipefail
cd "$(dirname "$0")/.."

APP=Phosphor
VERSION="${VERSION:-0.2.0}"
BUNDLE_ID="${BUNDLE_ID:-io.github.nirvanasangsara.phosphor}"
LOCAL_IDENTITY="Phosphor Local"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

OUT="dist/$APP.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN_DIR/$APP" "$OUT/Contents/MacOS/$APP"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

in_ci() {
  [[ "${CI:-}" == "true" || -n "${GITHUB_ACTIONS:-}" || -n "${GITHUB_ACTION:-}" ]]
}

# Prints identity names (quoted as `security find-identity` does), one per line, no hashes.
codesigning_identities() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*\)"$/\1/p'
}

identity_exists() {
  local want="$1" name
  while IFS= read -r name; do
    [[ "$name" == "$want" ]] && return 0
  done < <(codesigning_identities)
  return 1
}

pick_existing_identity() {
  local name
  local -a preferred=()
  local -a apple_dev=()
  local -a rest=()
  while IFS= read -r name; do
    [[ -z "$name" || "$name" == "-" ]] && continue
    case "$name" in
      "Developer ID Application:"*) preferred+=("$name") ;;
      "Apple Development:"*) apple_dev+=("$name") ;;
      "$LOCAL_IDENTITY") preferred+=("$name") ;;
      *) rest+=("$name") ;;
    esac
  done < <(codesigning_identities)
  if ((${#preferred[@]})); then echo "${preferred[0]}"; return 0; fi
  if ((${#apple_dev[@]})); then echo "${apple_dev[0]}"; return 0; fi
  return 1
}

create_local_identity() {
  local tmp pass
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/phosphor-sign.XXXXXX")"
  # Always shred the temporary key material, even if import fails.
  cleanup() { rm -rf "$tmp"; }
  trap cleanup RETURN
  pass="$(/usr/bin/openssl rand -hex 16)"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -subj "/CN=${LOCAL_IDENTITY}/O=Phosphor/" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/cert.p12" -passout "pass:${pass}" -name "$LOCAL_IDENTITY" >/dev/null 2>&1
  local keychain="${HOME}/Library/Keychains/login.keychain-db"
  if [[ ! -f "$keychain" ]]; then
    keychain="${HOME}/Library/Keychains/login.keychain"
  fi
  security import "$tmp/cert.p12" -k "$keychain" -P "$pass" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  # Best-effort: allow codesign to use the key without a Keychain prompt.
  security set-key-partition-list -S "apple-tool:,apple:,codesign:" -s -k "" "$keychain" >/dev/null 2>&1 || true
  identity_exists "$LOCAL_IDENTITY"
}

resolve_identity() {
  if [[ -n "${PHOSPHOR_SIGN_IDENTITY:-}" ]]; then
    if identity_exists "$PHOSPHOR_SIGN_IDENTITY"; then
      echo "$PHOSPHOR_SIGN_IDENTITY"
      return 0
    fi
    echo "error: PHOSPHOR_SIGN_IDENTITY is set but not in the keychain: $PHOSPHOR_SIGN_IDENTITY" >&2
    return 1
  fi
  if pick="$(pick_existing_identity)"; then
    echo "$pick"
    return 0
  fi
  if in_ci; then
    return 1
  fi
  if create_local_identity; then
    echo "$LOCAL_IDENTITY"
    return 0
  fi
  return 1
}

if IDENTITY="$(resolve_identity)"; then
  echo "• signing with ${IDENTITY}"
  codesign --force --deep --sign "$IDENTITY" "$OUT" >/dev/null
else
  echo "• no local signing identity; ad-hoc signature"
  codesign --force --deep --sign - "$OUT" >/dev/null
fi

echo "✓ built $OUT"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x "$APP" 2>/dev/null || true
  open "$OUT"
fi
