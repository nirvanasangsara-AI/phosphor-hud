#!/usr/bin/env bash
# Downloads LiteLLM's public price table and writes packaging/litellm-prices.min.json.
# Only per-token costs are kept (input, output, cache read, cache creation) so the
# file stays under about 1 MB. build-app.sh copies it into the app bundle.
#
# Hosts, in order: raw.githubusercontent.com, then cdn.jsdelivr.net. The first one
# that returns a JSON object wins.
set -euo pipefail
cd "$(dirname "$0")/.."

urls=(
  "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
  "https://cdn.jsdelivr.net/gh/BerriAI/litellm@main/model_prices_and_context_window.json"
)
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
ok=0
for url in "${urls[@]}"; do
  if curl -fsSL --max-time 60 "$url" -o "$tmp"; then
    ok=1
    echo "• downloaded $url"
    break
  fi
  echo "• $url failed, trying the next host"
done
if [[ "$ok" != 1 ]]; then
  echo "error: could not download the LiteLLM price table" >&2
  exit 1
fi

mkdir -p packaging
python3 - "$tmp" packaging/litellm-prices.min.json <<'PY'
import datetime, json, sys
from pathlib import Path
raw = json.loads(Path(sys.argv[1]).read_text())
keep = (
    "input_cost_per_token",
    "output_cost_per_token",
    "cache_read_input_token_cost",
    "cache_creation_input_token_cost",
)
out = {"_phosphor_bundled": datetime.date.today().isoformat()}
for key, val in raw.items():
    if not isinstance(val, dict):
        continue
    slim = {}
    for field in keep:
        number = val.get(field)
        if isinstance(number, bool) or not isinstance(number, (int, float)):
            continue
        slim[field] = number
    if "input_cost_per_token" in slim and "output_cost_per_token" in slim:
        out[key] = slim
text = json.dumps(out, separators=(",", ":"), ensure_ascii=False)
dest = Path(sys.argv[2])
dest.write_text(text)
size = len(text.encode())
print(f"• {dest} · {len(out) - 1} models · {size} bytes")
if size > 1_000_000:
    raise SystemExit("error: bundled price table is over 1 MB")
PY
