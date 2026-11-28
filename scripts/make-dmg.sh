#!/usr/bin/env bash
# Packs a signed dist/Phosphor.app into dist/Phosphor.dmg.
# The image volume is named Phosphor and contains the app plus an Applications symlink,
# so a person can drag Phosphor into Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-dist/Phosphor.app}"
DMG="${2:-dist/Phosphor.dmg}"
VOLNAME="Phosphor"

[[ -d "$APP" ]] || { echo "error: missing $APP (build the app first)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/phosphor-dmg.XXXXXX")"
MOUNT=""
cleanup() {
  if [[ -n "$MOUNT" && -d "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

APP_KB="$(du -sk "$APP" | awk '{print $1}')"
SIZE_MB="$(( APP_KB / 1024 + 40 ))"
if (( SIZE_MB < 64 )); then SIZE_MB=64; fi

# A read-write image, then a compressed one. Creating the symlink on the
# mounted volume keeps it a symlink (srcfolder copies sometimes follow it).
# Do not pass -format here: on current macOS, hdiutil create -format requires
# -srcfolder, and a sized -fs image is already read-write.
hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname "$VOLNAME" "$WORK/rw.dmg"
if [[ -f "$WORK/rw.dmg" ]]; then
  RW="$WORK/rw.dmg"
elif [[ -f "$WORK/rw.dmg.dmg" ]]; then
  RW="$WORK/rw.dmg.dmg"
else
  echo "error: hdiutil did not create a read-write image" >&2
  ls -la "$WORK" >&2
  exit 1
fi

MOUNT="$WORK/mnt"
mkdir -p "$MOUNT"
hdiutil attach "$RW" -nobrowse -readwrite -mountpoint "$MOUNT"
ditto "$APP" "$MOUNT/Phosphor.app"
ln -s /Applications "$MOUNT/Applications"
sync
hdiutil detach "$MOUNT"
MOUNT=""

rm -f "$DMG" "${DMG}.dmg"
hdiutil convert "$RW" -format UDZO -ov -o "$DMG"
if [[ ! -f "$DMG" && -f "${DMG}.dmg" ]]; then
  mv "${DMG}.dmg" "$DMG"
fi
[[ -f "$DMG" ]] || { echo "error: DMG was not written to $DMG" >&2; exit 1; }

MOUNT="$WORK/check"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT"
NAME="$(diskutil info "$MOUNT" | sed -n 's/^ *Volume Name: *//p' | head -1 | sed 's/[[:space:]]*$//')"
[[ "$NAME" == "$VOLNAME" ]] || { echo "error: volume name is '$NAME', expected $VOLNAME" >&2; exit 1; }
[[ -d "$MOUNT/Phosphor.app" ]] || { echo "error: Phosphor.app is missing from the image" >&2; exit 1; }
[[ -L "$MOUNT/Applications" ]] || { echo "error: Applications symlink is missing from the image" >&2; exit 1; }
TARGET="$(readlink "$MOUNT/Applications")"
[[ "$TARGET" == "/Applications" ]] || { echo "error: Applications points at '$TARGET'" >&2; exit 1; }
codesign --verify --verbose=2 "$MOUNT/Phosphor.app"
hdiutil detach "$MOUNT"
MOUNT=""

echo "✓ $DMG (volume $VOLNAME)"
