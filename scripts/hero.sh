#!/usr/bin/env bash
# README hero + chart images from demo data (no real accounts): docs/assets/hero.png, docs/assets/chart.png.
# Needs a built dist/Phosphor.app and Screen Recording permission for your terminal.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=dist/Phosphor.app/Contents/MacOS/Phosphor
OUT=docs/assets
DOMAIN=io.github.nirvanasangsara.phosphor
THEME="${THEME:-clean}"
MARGIN=36
TMP="$(mktemp -d)"
mkdir -p "$OUT"
defaults export "$DOMAIN" "$TMP/prefs.plist" 2>/dev/null || true
restore() {
  pkill -f "$APP --demo" 2>/dev/null || true
  defaults delete "$DOMAIN" 2>/dev/null || true
  if [[ -s "$TMP/prefs.plist" ]]; then defaults import "$DOMAIN" "$TMP/prefs.plist"; fi
  rm -rf "$TMP"
}
trap restore EXIT
cat > "$TMP/bounds.swift" <<'SWIFT'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Phosphor"
    && (w[kCGWindowLayer as String] as? Int ?? 0) == 3 {
    let b = w[kCGWindowBounds as String] as! [String: Double]
    print("\(Int(b["X"]!)),\(Int(b["Y"]!)),\(Int(b["Width"]!)),\(Int(b["Height"]!))")
    break
}
SWIFT
swiftc -O "$TMP/bounds.swift" -o "$TMP/bounds" 2>/dev/null
shoot() {  # shoot <file> <showChart> <showDevStats>
  pkill -x Phosphor 2>/dev/null || true; sleep 0.8
  defaults write "$DOMAIN" theme "$THEME"
  defaults write "$DOMAIN" compact -bool false
  defaults write "$DOMAIN" opacity -float 1
  defaults write "$DOMAIN" showChart -bool "$2"
  defaults write "$DOMAIN" showDevStats -bool "$3"
  defaults write "$DOMAIN" collapsedGroups -array
  "$APP" --demo --stage >/dev/null 2>&1 & disown
  sleep 4
  IFS=, read -r x y w h < <("$TMP/bounds")
  screencapture -x -o -R "$((x - MARGIN)),$((y - MARGIN)),$((w + 2 * MARGIN)),$((h + 2 * MARGIN))" "$1"
  echo "✓ $1"
}
shoot "$OUT/hero.png" false true
shoot "$OUT/chart.png" true true
