#!/usr/bin/env bash
# T9 (cloud only): exhaust node capacity so pods go Pending; the Cluster
# Autoscaler must add a node and every pod must then schedule.
#
# Injection: raise each pod's CPU request to CPU_REQ and pin the HPA at its
# max, so 8 x CPU_REQ exceeds what the starting nodes can hold.
# Pass: Pending pods appear, the node count rises, and all replicas are Ready
#       within DEADLINE seconds (default 600).
# Everything is restored afterwards. The Cluster Autoscaler removes the extra
# node(s) by itself once they are idle (~10 min); this script does not wait.
set -u
cd "$(dirname "$0")" && . ./lib.sh

CPU_REQ="${CPU_REQ:-500m}"
DEADLINE="${DEADLINE:-600}"
HPA="$DEPLOY"

node_count() { kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '; }
ready_node_count() {
  kc get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l | tr -d ' '
}
# Pods the scheduler could not place. Phase=Pending alone is not enough: it also
# covers pods that are scheduled but still pulling images or starting containers.
pending_count() {
  kc get pods -l "$APP_SELECTOR" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="PodScheduled")].status}{"\n"}{end}' 2>/dev/null |
    grep -c False
}

log "T9 - Node capacity exhausted (Cluster Autoscaler)"

if kc get nodes -o jsonpath='{.items[*].spec.providerID}' | grep -q 'kind://'; then
  fail "this is a kind cluster - T9 needs a cloud node pool with the Cluster Autoscaler"
  exit 1
fi
require_ready 2

MAX=$(kc get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}')
ORIG_MIN=$(kc get hpa "$HPA" -o jsonpath='{.spec.minReplicas}')
ORIG_RES=$(kc get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].resources}')
NODES_BEFORE=$(ready_node_count)
info "nodes before: $NODES_BEFORE; forcing $MAX replicas at ${CPU_REQ} CPU each"

restore() {
  log "restoring HPA minReplicas=$ORIG_MIN and original resources"
  kc patch hpa "$HPA" --type=merge -p "{\"spec\":{\"minReplicas\":$ORIG_MIN}}" >/dev/null
  kc patch deploy "$DEPLOY" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources\",\"value\":$ORIG_RES}]" >/dev/null
}
trap restore EXIT

START=$(date +%s)
kc set resources deploy "$DEPLOY" --requests=cpu="$CPU_REQ" --limits=cpu="$CPU_REQ" >/dev/null
kc patch hpa "$HPA" --type=merge -p "{\"spec\":{\"minReplicas\":$MAX}}" >/dev/null

PENDING_AT="" NODE_AT="" ALL_AT="" PEAK_PENDING=0 NODES_MAX=$NODES_BEFORE LAST=""
while :; do
  T=$(( $(date +%s) - START ))
  P=$(pending_count) N=$(ready_node_count) R=$(ready_count)
  [ -z "$PENDING_AT" ] && [ "$P" -gt 0 ] && PENDING_AT=$T
  [ "$P" -gt "$PEAK_PENDING" ] && PEAK_PENDING=$P
  [ -z "$NODE_AT" ] && [ "$N" -gt "$NODES_BEFORE" ] && NODE_AT=$T
  [ "$N" -gt "$NODES_MAX" ] && NODES_MAX=$N
  if [ "$P/$N/$R" != "$LAST" ]; then
    info "t=${T}s  pending=$P ready_pods=$R/$MAX ready_nodes=$N"
    LAST="$P/$N/$R"
  fi
  if [ "$R" -ge "$MAX" ] && [ "$P" -eq 0 ]; then
    ALL_AT=$T
    break
  fi
  [ "$T" -ge "$DEADLINE" ] && break
  sleep 5
done
END=$(date +%s)

echo
kc get nodes
echo
kc get events -A --field-selector reason=TriggeredScaleUp --sort-by=.lastTimestamp 2>/dev/null | tail -n 3
echo

OK=0
if [ -z "$PENDING_AT" ]; then
  fail "no pod ever went Pending - capacity was never exhausted (raise CPU_REQ)"
  OK=1
else
  pass "pods went Pending at ${PENDING_AT}s (peak $PEAK_PENDING)"
fi
if [ -z "$NODE_AT" ]; then
  fail "no node was added within ${DEADLINE}s"
  OK=1
else
  pass "Cluster Autoscaler added capacity: $NODES_BEFORE -> $NODES_MAX nodes, first new node Ready at ${NODE_AT}s"
fi
if [ -z "$ALL_AT" ]; then
  fail "only $(ready_count)/$MAX pods Ready after ${DEADLINE}s"
  OK=1
else
  pass "all $MAX replicas Ready at ${ALL_AT}s (deadline ${DEADLINE}s)"
fi

OUT_DIR="../load/results"
mkdir -p "$OUT_DIR"
WINDOWS="$OUT_DIR/t9-$(date +%Y%m%d-%H%M%S)-windows.tsv"
printf 'scenario\tresult\tstart_ms\tend_ms\nt9-cluster-autoscaler\t%s\t%s\t%s\n' \
  "$([ $OK -eq 0 ] && echo PASS || echo FAIL)" "$((START * 1000))" "$((END * 1000))" >"$WINDOWS"
info "windows: ${WINDOWS#../}"
info "the autoscaler removes the extra node(s) once idle; watch with: kubectl get nodes -w"
exit $OK
