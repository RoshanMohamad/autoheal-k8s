#!/usr/bin/env bash
# T3: block the Node event loop so the process is alive but cannot answer.
# The liveness probe must fail its threshold and restart the container.
# Probe timings: periodSeconds 10, failureThreshold 3 -> ~30s to trigger.
set -u
cd "$(dirname "$0")" && . ./lib.sh

HANG_MS="${HANG_MS:-45000}"
DEADLINE="${DEADLINE:-120}"

log "T3 - Hung app (/hang blocks the event loop)"
require_ready 2

TARGET=$(first_pod)

# The app clamps /hang to MAX_HANG_MS. If that ceiling is at or below the
# liveness budget (periodSeconds x failureThreshold), the hang can end before
# the third probe failure and the test flakes rather than fails honestly.
MAX_HANG=$(kc get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MAX_HANG_MS")].value}' 2>/dev/null)
MAX_HANG="${MAX_HANG:-$(kc get cm "${DEPLOY}-config" -o jsonpath='{.data.MAX_HANG_MS}' 2>/dev/null)}"
PERIOD=$(kc get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.periodSeconds}' 2>/dev/null)
THRESHOLD=$(kc get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.failureThreshold}' 2>/dev/null)
if [ -n "$MAX_HANG" ] && [ -n "$PERIOD" ] && [ -n "$THRESHOLD" ]; then
  NEEDED_MS=$(( PERIOD * THRESHOLD * 1000 ))
  info "liveness budget: ${PERIOD}s x ${THRESHOLD} = $((NEEDED_MS / 1000))s; app clamps /hang at $((MAX_HANG / 1000))s"
  if [ "$MAX_HANG" -le "$NEEDED_MS" ]; then
    fail "MAX_HANG_MS (${MAX_HANG}ms) does not exceed the liveness budget (${NEEDED_MS}ms); raise it or this test cannot pass reliably"
    exit 1
  fi
fi

BEFORE_RESTARTS=$(restart_total)
BEFORE_READY=$(ready_count)
info "hanging pod $TARGET for ${HANG_MS}ms"

# The request never returns - the event loop is blocked - so fire and forget.
pod_fetch "$TARGET" "/hang?durationMs=${HANG_MS}" >/dev/null 2>&1 &
HANG_PID=$!

EXPECTED=$((BEFORE_RESTARTS + 1))
if ! ELAPSED=$(wait_for "$DEADLINE" "$EXPECTED" restart_total); then
  fail "liveness probe did not restart the container within ${DEADLINE}s"
  kill "$HANG_PID" 2>/dev/null
  kc describe pod "$TARGET" | grep -A 8 "Events:" | tail -8
  exit 1
fi
kill "$HANG_PID" 2>/dev/null

info "liveness killed the hung container after ${ELAPSED}s"
kc describe pod "$TARGET" 2>/dev/null | grep -i "liveness probe failed" | tail -2

READY_ELAPSED=$(wait_for "$DEADLINE" "$BEFORE_READY" ready_count)

echo
kc get pods -l "$APP_SELECTOR"
echo

if [ "$READY_ELAPSED" = "TIMEOUT" ]; then
  fail "pod did not recover within ${DEADLINE}s"
  exit 1
fi
pass "hung container detected by liveness, restarted, Ready again in ${READY_ELAPSED}s"
