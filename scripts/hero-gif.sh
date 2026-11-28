#!/usr/bin/env bash
# Build docs/assets/hero.gif from demo screenshots already in the repo.
# No live account and no macOS capture: scripts/hero.sh and scripts/screenshots.sh
# need a display and Screen Recording. This only crossfades the demo stills.
#
#   docs/assets/chart.png
#   docs/screenshots/{clean,retro,matrix,glasses,raid}.png
#
# Needs python3, Pillow, and ffmpeg. gifsicle is optional (smaller file).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=docs/assets/hero.gif
WIDTH=420
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 1; }
python3 -c 'import PIL' 2>/dev/null || { echo "Pillow is required (pip install pillow)" >&2; exit 1; }
for f in docs/assets/chart.png docs/screenshots/clean.png docs/screenshots/retro.png \
         docs/screenshots/matrix.png docs/screenshots/glasses.png docs/screenshots/raid.png; do
  [[ -f "$f" ]] || { echo "missing $f" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WIDTH="$WIDTH" TMP="$TMP" python3 - <<'PY'
import os
from collections import deque
from pathlib import Path
from PIL import Image, ImageFilter

width = int(os.environ["WIDTH"])
tmp = Path(os.environ["TMP"])
srcs = [
    "docs/assets/chart.png",
    "docs/screenshots/clean.png",
    "docs/screenshots/retro.png",
    "docs/screenshots/matrix.png",
    "docs/screenshots/glasses.png",
    "docs/screenshots/raid.png",
]
hold, fade, steps = 1.8, 0.45, 4

def card_bbox(im, thresh=18):
    w, h = im.size
    s = 4
    sm = im.convert("RGB").resize((max(1, w // s), max(1, h // s)), Image.BILINEAR)
    px = sm.load()
    sw, sh = sm.size
    mag = [[0] * sw for _ in range(sh)]
    for y in range(1, sh - 1):
        for x in range(1, sw - 1):
            r, g, b = px[x, y]
            r2, g2, b2 = px[x + 1, y]
            r3, g3, b3 = px[x, y + 1]
            mag[y][x] = abs(r - r2) + abs(g - g2) + abs(b - b2) + abs(r - r3) + abs(g - g3) + abs(b - b3)
    bg = [[False] * sw for _ in range(sh)]
    q = deque()
    for x in range(sw):
        q.append((x, 0)); q.append((x, sh - 1))
    for y in range(sh):
        q.append((0, y)); q.append((sw - 1, y))
    while q:
        x, y = q.popleft()
        if x < 0 or y < 0 or x >= sw or y >= sh or bg[y][x]:
            continue
        if mag[y][x] > thresh and not (x < 3 or y < 3 or x >= sw - 3 or y >= sh - 3):
            continue
        bg[y][x] = True
        q.append((x + 1, y)); q.append((x - 1, y)); q.append((x, y + 1)); q.append((x, y - 1))
    minx, miny, maxx, maxy = sw, sh, 0, 0
    found = False
    for y in range(sh):
        for x in range(sw):
            if not bg[y][x]:
                found = True
                minx, miny = min(minx, x), min(miny, y)
                maxx, maxy = max(maxx, x), max(maxy, y)
    if not found:
        return (0, 0, w, h)
    pad = 2
    minx, miny = max(0, minx - pad), max(0, miny - pad)
    maxx, maxy = min(sw - 1, maxx + pad), min(sh - 1, maxy + pad)
    return (minx * s, miny * s, min(w, (maxx + 1) * s), min(h, (maxy + 1) * s))

def wallpaper(im, bbox, W, H):
    """Stage gradient from pixels outside the HUD card, so letterboxing is wallpaper."""
    gw, gh = 28, 48
    plate = Image.new("RGB", (gw, gh))
    pp, src = plate.load(), im.load()
    x0, y0, x1, y1 = bbox
    w, h = im.size
    for gy in range(gh):
        sy = int(gy / (gh - 1) * (h - 1))
        for gx in range(gw):
            sx = int(gx / (gw - 1) * (w - 1))
            if x0 <= sx < x1 and y0 <= sy < y1:
                dl, dr, dt, db = sx - x0, x1 - 1 - sx, sy - y0, y1 - 1 - sy
                m = min(dl, dr, dt, db)
                if m == dl:
                    sx = max(0, x0 - 3)
                elif m == dr:
                    sx = min(w - 1, x1 + 2)
                elif m == dt:
                    sy = max(0, y0 - 3)
                else:
                    sy = min(h - 1, y1 + 2)
            pp[gx, gy] = src[min(w - 1, max(0, sx)), min(h - 1, max(0, sy))]
    return plate.resize((W, H), Image.Resampling.BICUBIC).filter(ImageFilter.GaussianBlur(radius=6))

items = []
for path in srcs:
    im = Image.open(path).convert("RGB")
    items.append((path, im, card_bbox(im)))

theme_h = []
for path, im, b in items:
    if "/clean.png" in path or path.endswith(("retro.png", "matrix.png", "glasses.png")):
        theme_h.append(round((b[3] - b[1]) * width / (b[2] - b[0])))
H = max(theme_h)
stage = next(wallpaper(im, b, width, H) for path, im, b in items if path.endswith("clean.png"))

frames = []
for path, im, b in items:
    cropped = im.crop(b)
    cw, ch = cropped.size
    scale = min(width / cw, H / ch)
    nw, nh = max(1, round(cw * scale)), max(1, round(ch * scale))
    fg = cropped.resize((nw, nh), Image.Resampling.LANCZOS)
    canvas = stage.copy()
    canvas.paste(fg, ((width - nw) // 2, (H - nh) // 2))
    frames.append(canvas)

seq = []
n = 0
def emit(im, dur):
    global n
    im.save(tmp / f"f{n:03d}.png")
    seq.append((f"f{n:03d}.png", dur))
    n += 1

gaps = steps - 1
for i, a in enumerate(frames):
    b = frames[(i + 1) % len(frames)]
    emit(a, hold)
    for s in range(1, steps):
        emit(Image.blend(a, b, s / steps), fade / gaps)

lines = []
for name, dur in seq:
    lines += [f"file '{name}'", f"duration {dur:.3f}"]
lines.append(f"file '{seq[-1][0]}'")
(tmp / "list.txt").write_text("\n".join(lines) + "\n")
print(f"frames {len(seq)}  canvas {width}x{H}")
PY

ffmpeg -loglevel error -y -f concat -safe 0 -i "$TMP/list.txt" \
  -vf "split[a][b];[a]palettegen=stats_mode=single:max_colors=256[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
  -loop 0 "$TMP/hero.gif"

if command -v gifsicle >/dev/null; then
  gifsicle -O3 --lossy=35 -o "$OUT" "$TMP/hero.gif"
else
  cp "$TMP/hero.gif" "$OUT"
  echo "gifsicle not installed; left the larger ffmpeg GIF" >&2
fi
echo "✓ $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
