#!/usr/bin/env bash
# Shared helpers for the chaos scenarios.

RELEASE="${RELEASE:-autoheal}"
NAMESPACE="${NAMESPACE:-default}"
APP_SELECTOR="app.kubernetes.io/name=autoheal-api"
DEPLOY="${RELEASE}-autoheal-api"

kc() { kubectl -n "$NAMESPACE" "$@"; }

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
pass() { printf '\033[1;32m    PASS: %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m    FAIL: %s\033[0m\n' "$*"; }

app_pods() {
  kc get pods -l "$APP_SELECTOR" --no-headers 2>/dev/null
}

ready_count() {
  app_pods | awk '{split($2,a,"/"); if (a[1]==a[2] && $3=="Running") c++} END {print c+0}'
}

restart_total() {
  kc get pods -l "$APP_SELECTOR" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null |
    awk '{s+=$1} END {print s+0}'
}

endpoint_count() {
  kc get endpoints "$DEPLOY" \
    -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' '
}

# Runs a command inside a pod using the app's own Node runtime, so no extra
# image (curl, busybox) has to be pulled into the cluster.
pod_fetch() {
  local pod="$1" path="$2" method="${3:-GET}" body="${4:-}"
  local opts="{method:'${method}'"
  if [ -n "$body" ]; then
    opts="${opts},headers:{'content-type':'application/json'},body:JSON.stringify(${body})"
  fi
  opts="${opts}}"
  kc exec "$pod" -- node -e \
    "fetch('http://localhost:3000${path}',${opts}).then(r=>r.text()).then(t=>console.log(t)).catch(e=>console.log('ERR',e.message))" 2>&1
}

first_pod() {
  app_pods | awk '$2 ~ /^[0-9]+\/[0-9]+$/ {print $1; exit}'
}

# Waits until `cmd` prints the expected value, up to `timeout` seconds.
# Prints the elapsed whole seconds on success, or "TIMEOUT".
wait_for() {
  local timeout="$1" expected="$2"; shift 2
  local start elapsed actual
  start=$(date +%s)
  while :; do
    actual=$("$@" 2>/dev/null)
    elapsed=$(( $(date +%s) - start ))
    if [ "$actual" = "$expected" ]; then
      echo "$elapsed"
      return 0
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "TIMEOUT"
      return 1
    fi
    sleep 2
  done
}

# Waits until the app is genuinely quiet: the expected number of pods Ready AND
# the restart count unchanged across several consecutive samples. A fixed sleep
# is not enough between scenarios - a container still restarting from the
# previous test would otherwise break the next one (T4 in particular asserts
# that the restart count does NOT change).
settle() {
  local want="${1:-2}" timeout="${2:-180}"
  local start last stable ready restarts
  start=$(date +%s)
  last=""
  stable=0
  while :; do
    ready=$(ready_count)
    restarts=$(restart_total)
    if [ "$ready" = "$want" ] && [ "$restarts" = "$last" ]; then
      stable=$((stable + 1))
      if [ "$stable" -ge 3 ]; then
        return 0
      fi
    else
      stable=0
    fi
    last="$restarts"
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      return 1
    fi
    sleep 3
  done
}

require_ready() {
  local want="${1:-2}"
  local have
  have=$(ready_count)
  if [ "$have" -lt "$want" ]; then
    fail "expected at least $want ready pod(s) before starting, found $have"
    kc get pods -l "$APP_SELECTOR"
    exit 1
  fi
  info "starting state: $have ready pod(s), $(restart_total) total restarts"
}
