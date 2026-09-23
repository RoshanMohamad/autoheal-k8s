#!/usr/bin/env bash
# Screenshots the autoheal Grafana dashboard over a time window, as PNG
# evidence for the test report. Uses a headless Chrome/Edge and Grafana's
# anonymous read-only access (see values-kube-prometheus-stack.yaml).
#
#   bash observability/snapshot.sh <from_ms> <to_ms> <out.png>
#   bash observability/snapshot.sh <windows.tsv> <out_dir>
#
# The second form takes the per-scenario windows file written by
# chaos/run-all.sh or chaos/t5-t6-autoscale.sh and captures one PNG per row.
# Windows are padded by PAD_S seconds (default 60) either side for context.
set -u

PAD_S="${PAD_S:-60}"
PORT="${GRAFANA_PORT:-3000}"
WIDTH="${WIDTH:-1600}"
HEIGHT="${HEIGHT:-1500}"

find_browser() {
  [ -n "${BROWSER:-}" ] && { echo "$BROWSER"; return; }
  for b in chromium chromium-browser google-chrome \
    "/c/Program Files/Google/Chrome/Application/chrome.exe" \
    "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
    if command -v "$b" >/dev/null 2>&1 || [ -x "$b" ]; then echo "$b"; return; fi
  done
}

# Native Windows browsers need a Windows path for --screenshot.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else echo "$1"; fi
}

BROWSER_BIN=$(find_browser)
if [ -z "$BROWSER_BIN" ]; then
  echo "no Chrome/Chromium/Edge found; set BROWSER=/path/to/browser" >&2
  exit 1
fi

kubectl -n monitoring port-forward svc/monitoring-grafana "$PORT:80" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 20); do
  curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1 && break
  sleep 1
done

shoot() {
  local from=$(( $1 - PAD_S * 1000 )) to=$(( $2 + PAD_S * 1000 )) out="$3"
  mkdir -p "$(dirname "$out")"
  local url="http://localhost:$PORT/d/autoheal-api/?orgId=1&from=$from&to=$to&var-namespace=default&kiosk"
  # virtual-time-budget lets panel queries finish before the capture.
  "$BROWSER_BIN" --headless=new --disable-gpu --hide-scrollbars \
    --window-size="$WIDTH,$HEIGHT" --virtual-time-budget=20000 \
    --screenshot="$(native_path "$out")" "$url" >/dev/null 2>&1
  if [ -s "$out" ]; then echo "wrote $out"; else echo "failed: $out" >&2; return 1; fi
}

if [ "${1:-}" != "" ] && [ -f "$1" ]; then
  WINDOWS="$1" OUT_DIR="${2:?usage: snapshot.sh <windows.tsv> <out_dir>}"
  tail -n +2 "$WINDOWS" | while IFS=$'\t' read -r name _ start end _; do
    shoot "$start" "$end" "$OUT_DIR/$name.png"
  done
else
  shoot "${1:?from_ms}" "${2:?to_ms}" "${3:?out.png}"
fi
