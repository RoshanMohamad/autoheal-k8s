#!/usr/bin/env bash
# T8: drain a worker node. The PodDisruptionBudget must prevent the drain from
# taking available replicas below its minimum at any point.
# Samples availability throughout the drain rather than only checking the end state.
set -u
cd "$(dirname "$0")" && . ./lib.sh

log "T8 - Node drain (PDB protects minimum availability)"
require_ready 2

PDB_MIN=$(kc get pdb "$DEPLOY" -o jsonpath='{.spec.minAvailable}' 2>/dev/null)
PDB_MIN="${PDB_MIN:-1}"
info "PodDisruptionBudget minAvailable: $PDB_MIN"

NODE="${NODE:-$(kc get pods -l "$APP_SELECTOR" -o jsonpath='{.items[0].spec.nodeName}')}"
if [ -z "$NODE" ]; then
  fail "could not determine a node to drain"
  exit 1
fi
info "draining node: $NODE"

# Sample availability in the background for the duration of the drain.
SAMPLES="$(mktemp)"
(
  while :; do
    ready_count >> "$SAMPLES"
    sleep 2
  done
) &
SAMPLER=$!

kc drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=180s 2>&1 | tail -4

sleep 4
kill "$SAMPLER" 2>/dev/null

MIN_SEEN=$(sort -n "$SAMPLES" | head -1)
SAMPLE_COUNT=$(wc -l < "$SAMPLES" | tr -d ' ')
rm -f "$SAMPLES"

echo
kc get pods -l "$APP_SELECTOR" -o wide
echo
info "availability samples taken: $SAMPLE_COUNT, minimum ready observed: $MIN_SEEN"

log "uncordoning $NODE"
kc uncordon "$NODE" >/dev/null

if [ "$MIN_SEEN" -lt "$PDB_MIN" ]; then
  fail "ready replicas fell to $MIN_SEEN, below PDB minimum of $PDB_MIN"
  exit 1
fi
pass "ready replicas never dropped below $PDB_MIN (lowest observed: $MIN_SEEN)"
