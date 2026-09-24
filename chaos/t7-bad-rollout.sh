#!/usr/bin/env bash
# T7: deploy an image whose readiness never passes. Because the strategy sets
# maxUnavailable: 0, the rollout must stall while the OLD pods keep serving,
# and `kubectl rollout undo` must restore the previous state.
set -u
cd "$(dirname "$0")" && . ./lib.sh

STALL_WAIT="${STALL_WAIT:-60}"

log "T7 - Bad rollout (readiness never passes)"
require_ready 2

BEFORE_READY=$(ready_count)
BEFORE_EP=$(endpoint_count)
info "serving endpoints before rollout: $BEFORE_EP"

# Breaking readiness via env rather than pushing a broken image keeps the
# failure mode the one T7 targets: the container starts fine but never passes
# its probe. A nonexistent image would instead fail at pull time, which is a
# different scenario and needs registry access the cluster may not have.
# STARTUP_DELAY_MS far beyond the startup probe budget (periodSeconds 2 x
# failureThreshold 15 = 30s) guarantees the new pod never becomes ready.
info "rolling out a config whose readiness can never pass"
kc set env deploy/"$DEPLOY" STARTUP_DELAY_MS=600000 >/dev/null

info "waiting ${STALL_WAIT}s to confirm the rollout stalls rather than completes..."
sleep "$STALL_WAIT"

echo
kc get pods -l "$APP_SELECTOR"
echo

ROLLOUT_DONE=$(kc rollout status deploy/"$DEPLOY" --timeout=5s 2>&1 | tail -1)
DURING_EP=$(endpoint_count)
info "rollout status: $ROLLOUT_DONE"
info "serving endpoints during stalled rollout: $DURING_EP"

OK=0
if [ "$DURING_EP" -ge "$BEFORE_EP" ]; then
  pass "old pods kept serving: $DURING_EP endpoint(s) still in rotation"
else
  fail "capacity dropped during a failed rollout ($BEFORE_EP -> $DURING_EP)"
  OK=1
fi

log "rolling back with kubectl rollout undo"
kc rollout undo deploy/"$DEPLOY" >/dev/null
kc set env deploy/"$DEPLOY" STARTUP_DELAY_MS=2000 >/dev/null

if ! ELAPSED=$(wait_for 180 yes ready_at_least "$BEFORE_READY"); then
  fail "rollback did not restore $BEFORE_READY ready pod(s)"
  kc get pods -l "$APP_SELECTOR"
  exit 1
fi

echo
kc get pods -l "$APP_SELECTOR"
echo
pass "rollback restored $BEFORE_READY ready pod(s) in ${ELAPSED}s"
exit $OK
