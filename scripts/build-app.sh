#!/usr/bin/env bash
# Builds dist/Phosphor.app (ad-hoc signed). Usage:
#   ./scripts/build-app.sh            # native arch
#   UNIVERSAL=1 ./scripts/build-app.sh  # arm64 + x86_64 (needs full Xcode)
#   ./scripts/build-app.sh --run      # build and launch
set -euo pipefail
cd "$(dirname "$0")/.."

APP=Phosphor
VERSION="${VERSION:-0.2.0}"
BUNDLE_ID="${BUNDLE_ID:-io.github.nirvanasangsara.phosphor}"

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

codesign --force --deep --sign - "$OUT" >/dev/null
echo "✓ built $OUT"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x "$APP" 2>/dev/null || true
  open "$OUT"
fi
