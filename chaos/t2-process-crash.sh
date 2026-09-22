#!/usr/bin/env bash
# T2: hit /crash so the process exits non-zero. The kubelet must restart the
# container in place (restartCount increments, pod name stays the same).
set -u
cd "$(dirname "$0")" && . ./lib.sh

DEADLINE="${DEADLINE:-60}"

log "T2 - Process crash (/crash calls process.exit(1))"
require_ready 2

TARGET=$(first_pod)
BEFORE_RESTARTS=$(restart_total)
BEFORE_READY=$(ready_count)
info "crashing pod $TARGET (restarts so far: $BEFORE_RESTARTS)"

pod_fetch "$TARGET" "/crash" "POST" >/dev/null 2>&1 || true

EXPECTED=$((BEFORE_RESTARTS + 1))
if ! RESTART_ELAPSED=$(wait_for "$DEADLINE" "$EXPECTED" restart_total); then
  fail "restart count did not reach $EXPECTED within ${DEADLINE}s"
  kc get pods -l "$APP_SELECTOR"
  exit 1
fi
info "restart count incremented after ${RESTART_ELAPSED}s"

READY_ELAPSED=$(wait_for "$DEADLINE" "$BEFORE_READY" ready_count)

echo
kc get pods -l "$APP_SELECTOR"
echo

if [ "$READY_ELAPSED" = "TIMEOUT" ]; then
  fail "pod did not return to Ready within ${DEADLINE}s"
  exit 1
fi
pass "container restarted in place and became Ready again in ${READY_ELAPSED}s"
info "pod $TARGET kept its name - restarted, not replaced"
