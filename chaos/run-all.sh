#!/usr/bin/env bash
# Runs every Week 4 chaos scenario in sequence and prints a results table.
# Scenarios are ordered least to most disruptive; the drain runs last.
set -u
cd "$(dirname "$0")" && . ./lib.sh

SCENARIOS="t1-pod-crash t2-process-crash t3-hang t4-unready t7-bad-rollout t8-node-drain"
RESULTS=""
FAILED=0

for s in $SCENARIOS; do
  if bash "./${s}.sh"; then
    RESULTS="${RESULTS}\n  ${s}\tPASS"
  else
    RESULTS="${RESULTS}\n  ${s}\tFAIL"
    FAILED=$((FAILED + 1))
  fi
  # Wait for genuine quiescence rather than a fixed sleep, so one scenario's
  # tail (a container still restarting) cannot fail the next one.
  if ! settle 2 180; then
    info "warning: cluster did not fully settle before the next scenario"
  fi
done

log "Results"
printf "%b\n" "$RESULTS" | column -t 2>/dev/null || printf "%b\n" "$RESULTS"
echo

if [ "$FAILED" -gt 0 ]; then
  fail "$FAILED scenario(s) failed"
  exit 1
fi
pass "all scenarios passed"
