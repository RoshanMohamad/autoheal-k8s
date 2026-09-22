#!/usr/bin/env bash
# T4: make one pod report 503 on /ready. It must leave the Service endpoints
# (so it receives no traffic) WITHOUT being restarted - readiness is not
# liveness. It must rejoin automatically once the window expires.
set -u
cd "$(dirname "$0")" && . ./lib.sh

SECONDS_UNREADY="${SECONDS_UNREADY:-45}"
DEADLINE="${DEADLINE:-120}"

log "T4 - Not ready (/ready returns 503 for ${SECONDS_UNREADY}s)"
require_ready 2

TARGET=$(first_pod)
BEFORE_EP=$(endpoint_count)
BEFORE_RESTARTS=$(restart_total)
info "endpoints before: $BEFORE_EP"
info "making pod $TARGET unready"

pod_fetch "$TARGET" "/chaos/unready" "POST" "{seconds:${SECONDS_UNREADY}}" >/dev/null

EXPECTED_EP=$((BEFORE_EP - 1))
if ! ELAPSED=$(wait_for "$DEADLINE" "$EXPECTED_EP" endpoint_count); then
  fail "pod was not removed from Service endpoints within ${DEADLINE}s"
  exit 1
fi
info "removed from endpoints after ${ELAPSED}s (now $EXPECTED_EP)"

AFTER_RESTARTS=$(restart_total)
if [ "$AFTER_RESTARTS" -ne "$BEFORE_RESTARTS" ]; then
  fail "pod was restarted ($BEFORE_RESTARTS -> $AFTER_RESTARTS); readiness must not restart containers"
  exit 1
fi
pass "no restart occurred - readiness correctly separated from liveness"

info "waiting for the unready window to expire..."
if ! RECOVER=$(wait_for "$DEADLINE" "$BEFORE_EP" endpoint_count); then
  fail "pod did not rejoin endpoints within ${DEADLINE}s"
  exit 1
fi

echo
kc get pods -l "$APP_SELECTOR"
echo
pass "rejoined Service endpoints automatically after ${RECOVER}s (back to $BEFORE_EP)"
