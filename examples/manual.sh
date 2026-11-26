#!/bin/sh
# Manual tracker for services with no usage API.
# Keep a tiny JSON per service in ~/.config/phosphor/manual/<id>.json, e.g.
#   {"plan":"Pro","windows":[{"label":"1D","used":30,"windowSeconds":86400,"resetsAt":"2026-11-25T00:00:00+09:00"}]}
# and update the "used" number yourself (or from a Shortcut / another script).
f="$HOME/.config/phosphor/manual/$1.json"
[ -f "$f" ] && cat "$f" || echo '{"windows":[]}'
