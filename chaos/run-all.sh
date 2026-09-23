#!/usr/bin/env bash
# Runs every Week 4 chaos scenario in sequence and prints a results table.
# Scenarios are ordered least to most disruptive; the drain runs last.
#
# Each scenario runs under steady k6 background traffic (BG_RATE req/s, see
# lib.sh), so the table reports failed user requests alongside PASS/FAIL.
# Set LOAD=0 to skip the traffic. Per-scenario time windows are written to
# load/results/ so observability/snapshot.sh can screenshot the dashboard for each.
set -u
cd "$(dirname "$0")" && . ./lib.sh

SCENARIOS="t1-pod-crash t2-process-crash t3-hang t4-unready t7-bad-rollout t8-node-drain"
LOAD="${LOAD:-1}"
OUT_DIR="../load/results"
mkdir -p "$OUT_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
WINDOWS="$OUT_DIR/chaos-$STAMP-windows.tsv"
printf 'scenario\tresult\tstart_ms\tend_ms\trequests\tfailed\n' >"$WINDOWS"

RESULTS="  scenario\tresult\trequests\tfailed\tavailability"
FAILED=0

for s in $SCENARIOS; do
  START_MS=$(( $(date +%s) * 1000 ))
  [ "$LOAD" = 1 ] && bg_load_start "$OUT_DIR/chaos-$STAMP-$s-k6.log"

  if bash "./${s}.sh"; then R=PASS; else R=FAIL; FAILED=$((FAILED + 1)); fi

  REQS="-" FAILS="-" AVAIL="-"
  if [ "$LOAD" = 1 ]; then
    set -- $(bg_load_stop)
    REQS="${1:-?}" FAILS="${2:-?}"
    AVAIL=$(awk -v r="$REQS" -v f="$FAILS" 'BEGIN {if (r > 0) printf "%.2f%%", (1 - f / r) * 100; else print "?"}')
    info "background traffic: $REQS requests, $FAILS failed ($AVAIL available)"
  fi
  END_MS=$(( $(date +%s) * 1000 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$s" "$R" "$START_MS" "$END_MS" "$REQS" "$FAILS" >>"$WINDOWS"
  RESULTS="${RESULTS}\n  ${s}\t${R}\t${REQS}\t${FAILS}\t${AVAIL}"

  # Wait for genuine quiescence rather than a fixed sleep, so one scenario's
  # tail (a container still restarting) cannot fail the next one.
  if ! settle 2 180; then
    info "warning: cluster did not fully settle before the next scenario"
  fi
done

log "Results"
printf "%b\n" "$RESULTS" | column -t 2>/dev/null || printf "%b\n" "$RESULTS"
echo
info "windows: ${WINDOWS#../}"

if [ "$FAILED" -gt 0 ]; then
  fail "$FAILED scenario(s) failed"
  exit 1
fi
pass "all scenarios passed"
