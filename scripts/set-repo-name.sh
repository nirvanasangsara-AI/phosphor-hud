#!/usr/bin/env bash
# Point README, docs and the Homebrew cask at the final GitHub repo: ./scripts/set-repo-name.sh phosphor
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="${1:?usage: set-repo-name.sh <repo-name>}"
OWNER="${OWNER:-nirvanasangsara-AI}"
for f in README.md docs/GUIDE.md docs/RELEASE.md docs/ROADMAP-ko.md packaging/homebrew/phosphor.rb; do
  [[ -f "$f" ]] || continue
  sed -i '' -e "s#nirvanasangsara-AI/phosphor-hud#$OWNER/$NAME#g" -e "s#OWNER/phosphor-hud#$OWNER/$NAME#g" \
            -e "s#cd phosphor-hud#cd $NAME#g" "$f"
done
echo "repo name set to $OWNER/$NAME"
