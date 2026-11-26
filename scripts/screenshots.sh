#!/usr/bin/env bash
# Regenerates docs/screenshots/*.png (one per built-in theme) and docs/screenshots/themes.gif
# from the demo data. Needs: a built dist/Phosphor.app, ffmpeg, Screen Recording permission
# for your terminal. Briefly shows a wallpaper window + the HUD in the middle of the screen.
#   ./scripts/screenshots.sh            # PNGs + GIF
#   ./scripts/screenshots.sh png        # PNGs only
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/Phosphor.app/Contents/MacOS/Phosphor
OUT=docs/screenshots
DOMAIN=io.github.nirvanasangsara.phosphor
THEMES=(clean retro matrix glasses raid)
MARGIN=36
TMP="$(mktemp -d)"
trap 'pkill -x Phosphor 2>/dev/null || true; restore; rm -rf "$TMP"' EXIT

[[ -x "$APP" ]] || { echo "build first: ./scripts/build-app.sh" >&2; exit 1; }
mkdir -p "$OUT"

# Keep the user's own prefs: snapshot, then restore on exit.
defaults export "$DOMAIN" "$TMP/prefs.plist" 2>/dev/null || true
restore() {
  defaults delete "$DOMAIN" 2>/dev/null || true
  if [[ -s "$TMP/prefs.plist" ]]; then defaults import "$DOMAIN" "$TMP/prefs.plist"; fi
}
defaults write "$DOMAIN" compact -bool false
defaults write "$DOMAIN" opacity -float 1
defaults write "$DOMAIN" clickThrough -bool false

# Tiny helper: print "x,y,w,h" (points, top-left origin) of the HUD window.
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

launch() {  # launch <theme> [env...]
  pkill -x Phosphor 2>/dev/null || true; sleep 0.5
  defaults write "$DOMAIN" theme "$1"; shift
  env "$@" "$APP" --demo --stage >/dev/null 2>&1 &
  disown
}

region() {  # HUD bounds grown by MARGIN (for the shadow)
  IFS=, read -r x y w h < <("$TMP/bounds")
  echo "$((x - MARGIN)),$((y - MARGIN)),$((w + 2 * MARGIN)),$((h + 2 * MARGIN))"
}

for t in "${THEMES[@]}"; do
  launch "$t"
  # Raid: wait for Grok to hit Exhausted so the pulse and combat log show.
  if [[ "$t" == raid ]]; then sleep 8; else sleep 3; fi
  screencapture -x -o -R "$(region)" "$OUT/$t.png"
  echo "✓ $OUT/$t.png"
done

[[ "${1:-}" == png ]] && exit 0

# Theme-switch GIF: one process cycling themes every 2.4 s, captured as a fixed box
# big enough for the tallest theme (HUD stays anchored at its top-left).
launch clean PHOSPHOR_CYCLE=2.4
sleep 1
IFS=, read -r x y _ _ < <("$TMP/bounds")
BOX="$((x - MARGIN)),$((y - MARGIN)),$((390 + 2 * MARGIN)),$((570 + 2 * MARGIN))"
# Frames take uneven time to grab (Matrix rain is slow), so record real timestamps and give
# each frame its true duration via the concat demuxer.
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
end=$(( $(date +%s) + 12 ))
i=0
: > "$TMP/times"
while (( $(date +%s) < end )); do
  f="$TMP/f$(printf %04d $i).png"
  now >> "$TMP/times"
  screencapture -x -o -R "$BOX" "$f"
  i=$((i + 1))
done
n=$i
python3 - "$TMP" <<'PY'
import sys, pathlib
d = pathlib.Path(sys.argv[1])
t = [float(x) for x in (d / "times").read_text().split()]
lines = []
for i in range(len(t)):
    dur = (t[i + 1] - t[i]) if i + 1 < len(t) else 0.15
    lines += [f"file '{d}/f{i:04d}.png'", f"duration {dur:.3f}"]
lines.append(f"file '{d}/f{len(t) - 1:04d}.png'")
(d / "list.txt").write_text("\n".join(lines) + "\n")
PY
ffmpeg -loglevel error -y -f concat -safe 0 -i "$TMP/list.txt" \
  -vf "fps=10,scale=iw/2:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a" \
  "$OUT/themes.gif"
echo "✓ $OUT/themes.gif ($n frames)"
