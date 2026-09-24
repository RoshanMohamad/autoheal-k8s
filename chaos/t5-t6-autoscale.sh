#!/usr/bin/env bash
# T5 + T6: traffic spike, then scale-in. One script because T6's clock starts
# the moment T5's load ends.
#
# T5 pass: HPA goes from minReplicas to maxReplicas within SCALE_UP_DEADLINE
#          (180s) of average CPU first exceeding the target, and the request
#          success rate over the whole spike stays >= 99.5%.
# T6 pass: replicas are back to minReplicas within SCALE_DOWN_DEADLINE (600s)
#          of load ending, and the count never goes back up on the way down
#          (no flapping).
#
# A per-sample timeline is written to load/results/ for the test report.
set -u
cd "$(dirname "$0")" && . ./lib.sh

SCALE_UP_DEADLINE="${SCALE_UP_DEADLINE:-180}"
SCALE_DOWN_DEADLINE="${SCALE_DOWN_DEADLINE:-600}"
SLO="${SLO:-0.995}"
SAMPLE="${SAMPLE:-5}"
HPA="$DEPLOY"

OUT_DIR="../load/results"
mkdir -p "$OUT_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
K6_LOG="$OUT_DIR/t5-t6-$STAMP-k6.log"
TIMELINE="$OUT_DIR/t5-t6-$STAMP-timeline.tsv"

# "current desired cpu%" - cpu% is empty until metrics-server has data.
hpa_state() {
  kc get hpa "$HPA" -o jsonpath='{.status.currentReplicas} {.status.desiredReplicas} {.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null
}
hpa_field() {
  kc get hpa "$HPA" -o jsonpath="{.spec.$1}" 2>/dev/null
}
hpa_cpu_known() {
  set -- $(hpa_state)
  [ -n "${3:-}" ] && echo yes || echo no
}

log "T5/T6 - Traffic spike and scale-in"

if ! kc get hpa "$HPA" >/dev/null 2>&1; then
  fail "HPA $HPA not found - deploy with autoscaling.enabled=true"
  exit 1
fi
MIN=$(hpa_field minReplicas)
MAX=$(hpa_field maxReplicas)
TARGET=$(hpa_field 'metrics[0].resource.target.averageUtilization')
info "HPA $HPA: min=$MIN max=$MAX target=${TARGET}% CPU"

# Without metrics-server the HPA shows <unknown> and never scales; fail fast
# with a useful message instead of burning 8 minutes of load.
if [ "$(wait_for 120 yes hpa_cpu_known)" = "TIMEOUT" ]; then
  fail "HPA has no CPU metric after 120s - is metrics-server installed? (make metrics-server)"
  kc describe hpa "$HPA" | tail -n 15
  exit 1
fi

if ! settle "$MIN" 600; then
  fail "app did not settle at $MIN ready replicas (still scaled out from a previous run?)"
  kc get hpa "$HPA"
  exit 1
fi
require_ready "$MIN"

# ---------------------------------------------------------------- T5: spike
log "T5 - starting k6 spike (log: ${K6_LOG#../})"
bash ../load/k6.sh ../load/spike.js >"$K6_LOG" 2>&1 &
K6_PID=$!

START=$(date +%s)
CROSS_AT=""
MAX_AT=""
LAST=""
PEAK=0
printf 'phase\tt_s\tcurrent\tdesired\tcpu_pct\tready\n' >"$TIMELINE"

while kill -0 "$K6_PID" 2>/dev/null; do
  T=$(( $(date +%s) - START ))
  set -- $(hpa_state)
  CUR="${1:-0}" DES="${2:-0}" CPU="${3:-}"
  READY=$(ready_count)
  printf 'T5\t%s\t%s\t%s\t%s\t%s\n' "$T" "$CUR" "$DES" "${CPU:--}" "$READY" >>"$TIMELINE"

  if [ -z "$CROSS_AT" ] && [ -n "$CPU" ] && [ "$CPU" -gt "$TARGET" ]; then
    CROSS_AT=$T
    info "t=${T}s  CPU ${CPU}% crossed the ${TARGET}% target"
  fi
  if [ -z "$MAX_AT" ] && [ "$CUR" -ge "$MAX" ]; then
    MAX_AT=$T
  fi
  [ "$CUR" -gt "$PEAK" ] && PEAK=$CUR
  if [ "$CUR/$DES" != "$LAST" ]; then
    info "t=${T}s  replicas current=$CUR desired=$DES ready=$READY cpu=${CPU:--}%"
    LAST="$CUR/$DES"
  fi
  sleep "$SAMPLE"
done
wait "$K6_PID"
K6_EXIT=$?
LOAD_END=$(date +%s)

result() { sed -n "s/^RESULT $1=//p" "$K6_LOG" | tail -n 1; }
REQS=$(result requests)
FAILED_RATE=$(result failed_rate)
P95=$(result p95_ms)
P95_REC=$(result p95_recovered_ms)

echo
if [ -z "$FAILED_RATE" ]; then
  fail "k6 produced no summary (exit $K6_EXIT) - see ${K6_LOG#../}"
  tail -n 20 "$K6_LOG"
  exit 1
fi
AVAIL=$(awk -v f="$FAILED_RATE" 'BEGIN {printf "%.3f", (1 - f) * 100}')
SLO_PCT=$(awk -v s="$SLO" 'BEGIN {print s * 100}')
info "k6: $REQS requests, availability ${AVAIL}%, p95 ${P95}ms overall, ${P95_REC}ms once scaled out"

T5_OK=1
if [ -z "$CROSS_AT" ]; then
  fail "CPU never exceeded the ${TARGET}% target - raise PEAK_VUS or WORK_MS"
  T5_OK=0
elif [ -z "$MAX_AT" ]; then
  fail "never reached $MAX replicas (peak $PEAK)"
  T5_OK=0
else
  SCALE_UP=$(( MAX_AT - CROSS_AT ))
  if [ "$SCALE_UP" -le "$SCALE_UP_DEADLINE" ]; then
    pass "scaled $MIN -> $MAX in ${SCALE_UP}s after CPU crossed ${TARGET}% (deadline ${SCALE_UP_DEADLINE}s)"
  else
    fail "scaled $MIN -> $MAX in ${SCALE_UP}s, over the ${SCALE_UP_DEADLINE}s deadline"
    T5_OK=0
  fi
fi
if awk -v f="$FAILED_RATE" -v s="$SLO" 'BEGIN {exit !((1 - f) >= s)}'; then
  pass "availability ${AVAIL}% during the spike (SLO ${SLO_PCT}%)"
else
  fail "availability ${AVAIL}% during the spike, below SLO ${SLO_PCT}%"
  T5_OK=0
fi

# ------------------------------------------------------------ T6: scale-in
log "T6 - load ended, waiting for scale-in to $MIN (deadline ${SCALE_DOWN_DEADLINE}s)"
LOWEST=999
FLAPS=0
DONE_AT=""
LAST=""
while :; do
  T=$(( $(date +%s) - LOAD_END ))
  set -- $(hpa_state)
  CUR="${1:-0}" DES="${2:-0}" CPU="${3:-}"
  printf 'T6\t%s\t%s\t%s\t%s\t%s\n' "$T" "$CUR" "$DES" "${CPU:--}" "$(ready_count)" >>"$TIMELINE"

  # Once the count has come down, any rise is a flap.
  if [ "$CUR" -gt "$LOWEST" ]; then
    FLAPS=$((FLAPS + 1))
    info "t=${T}s  FLAP: replicas rose from $LOWEST to $CUR"
  fi
  [ "$CUR" -lt "$LOWEST" ] && LOWEST=$CUR
  if [ "$CUR/$DES" != "$LAST" ]; then
    info "t=${T}s  replicas current=$CUR desired=$DES cpu=${CPU:--}%"
    LAST="$CUR/$DES"
  fi
  if [ "$CUR" -le "$MIN" ] && [ "$DES" -le "$MIN" ]; then
    DONE_AT=$T
    break
  fi
  [ "$T" -ge "$SCALE_DOWN_DEADLINE" ] && break
  sleep "$SAMPLE"
done

echo
kc get hpa "$HPA"
echo

T6_OK=1
if [ -z "$DONE_AT" ]; then
  fail "still at $CUR replicas ${SCALE_DOWN_DEADLINE}s after load ended"
  T6_OK=0
else
  pass "back to $MIN replicas ${DONE_AT}s after load ended (deadline ${SCALE_DOWN_DEADLINE}s)"
fi
if [ "$FLAPS" -eq 0 ]; then
  pass "no flapping during scale-in"
else
  fail "replica count rose $FLAPS time(s) during scale-in"
  T6_OK=0
fi

END=$(date +%s)
WINDOWS="$OUT_DIR/t5-t6-$STAMP-windows.tsv"
{
  printf 'scenario\tresult\tstart_ms\tend_ms\n'
  printf 't5-traffic-spike\t%s\t%s\t%s\n' "$([ $T5_OK -eq 1 ] && echo PASS || echo FAIL)" "$((START * 1000))" "$((LOAD_END * 1000))"
  printf 't6-scale-in\t%s\t%s\t%s\n' "$([ $T6_OK -eq 1 ] && echo PASS || echo FAIL)" "$((LOAD_END * 1000))" "$((END * 1000))"
} >"$WINDOWS"

info "timeline: ${TIMELINE#../}"
info "windows:  ${WINDOWS#../} (screenshots: bash observability/snapshot.sh ${WINDOWS#../} docs/img)"
[ "$T5_OK" -eq 1 ] && [ "$T6_OK" -eq 1 ]
