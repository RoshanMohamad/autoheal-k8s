#!/usr/bin/env bash
# T1: delete a random replica; the ReplicaSet must restore full capacity fast.
# Pass condition: replacement pod Ready in under 30s.
set -u
cd "$(dirname "$0")" && . ./lib.sh

DEADLINE="${DEADLINE:-30}"

log "T1 - Pod crash (kubectl delete pod)"
require_ready 2

BEFORE=$(ready_count)
VICTIM=$(app_pods | shuf -n 1 | awk '{print $1}')
info "deleting pod $VICTIM"

kc delete pod "$VICTIM" --wait=false >/dev/null

ELAPSED=$(wait_for "$DEADLINE" "$BEFORE" ready_count)

echo
kc get pods -l "$APP_SELECTOR"
echo

if [ "$ELAPSED" = "TIMEOUT" ]; then
  fail "capacity not restored within ${DEADLINE}s"
  exit 1
fi
pass "back to $BEFORE ready pod(s) in ${ELAPSED}s (deadline ${DEADLINE}s)"
