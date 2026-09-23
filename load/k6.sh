#!/usr/bin/env bash
# Runs a k6 script against the app through the ingress.
#
#   bash load/k6.sh load/spike.js
#   RATE=50 DURATION=2m bash load/k6.sh load/steady.js
#
# Uses a locally installed k6 if there is one (hitting localhost:8080, the port
# kind maps to the ingress). Otherwise runs the grafana/k6 image on the "kind"
# Docker network and targets the control-plane node directly, where the ingress
# controller holds hostPort 80 - so nothing extra has to be installed.
set -u

SCRIPT="${1:?usage: k6.sh <script.js> [extra k6 args]}"; shift
CLUSTER="${CLUSTER:-autoheal}"
HOST_HEADER="${HOST_HEADER:-autoheal.local}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:latest}"

# Forward the scripts' tuning knobs to k6 as -e flags, if set.
ENV_ARGS=(-e "HOST_HEADER=$HOST_HEADER")
for var in PEAK_VUS RAMP HOLD WORK_MS THINK_S RATE DURATION; do
  if [ -n "${!var:-}" ]; then
    ENV_ARGS+=(-e "$var=${!var}")
  fi
done

if command -v k6 >/dev/null 2>&1; then
  exec k6 run -e "BASE_URL=${BASE_URL:-http://localhost:8080}" "${ENV_ARGS[@]}" "$@" "$SCRIPT"
fi

# The script is piped over stdin rather than bind-mounted, which sidesteps
# Windows path translation between Git Bash and Docker Desktop.
# K6_NAME names the container so a caller can end the run early with
# `docker stop`; k6 treats SIGTERM as a graceful stop and still prints results.
NAME_ARGS=()
[ -n "${K6_NAME:-}" ] && NAME_ARGS=(--name "$K6_NAME")
# K6_NETWORK=bridge (with BASE_URL set to the load balancer) targets a cloud
# cluster instead of kind.
exec docker run --rm -i --network "${K6_NETWORK:-kind}" "${NAME_ARGS[@]}" "$K6_IMAGE" run \
  -e "BASE_URL=${BASE_URL:-http://${CLUSTER}-control-plane}" "${ENV_ARGS[@]}" "$@" - < "$SCRIPT"
