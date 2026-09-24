#!/usr/bin/env bash
# Week 6: creates the AKS cluster and deploys everything onto it.
#
#   bash infra/aks/up.sh
#   LOCATION=westeurope BUDGET_EMAIL=me@example.com bash infra/aks/up.sh
#
# Uses the subscription `az account show` reports unless SUBSCRIPTION_ID is set.
# CI_PRINCIPAL_ID (printed by ci-setup.sh) grants GitHub Actions deploy access.
#
# Prerequisites: az (logged in: `az login`), terraform, helm, kubectl, docker.
#
# Costs money from the moment it finishes. Tear down with infra/aks/down.sh.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..

# Strips the \r the Windows az CLI adds to every line under Git Bash.
az() { command az "$@" | tr -d '\r'; }

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
LOCATION="${LOCATION:-eastus}"
MAX_NODES="${MAX_NODES:-4}"
MONITORING="${MONITORING:-1}"
TAG="${TAG:-$(git rev-parse --short HEAD)}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "preflight: providers and vCPU quota in $LOCATION"
# New subscriptions often have these resource providers unregistered, and the
# first AKS create then fails halfway through.
for ns in Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.Compute Microsoft.Network Microsoft.Consumption; do
  az provider register --namespace "$ns" --subscription "$SUBSCRIPTION_ID" >/dev/null
done
# Student and trial subscriptions often cap a region at 4-6 vCPUs, which would
# make the Cluster Autoscaler fail silently at T9 instead of adding a node.
read -r USED LIMIT < <(az vm list-usage --location "$LOCATION" --subscription "$SUBSCRIPTION_ID" \
  --query "[?name.value=='cores'] | [0].[currentValue, limit]" -o tsv) || true
NEED=$((MAX_NODES * 2))
if [ -z "${LIMIT:-}" ]; then
  echo "    could not read the vCPU quota; skipping the check"
elif [ $((LIMIT - USED)) -lt "$NEED" ]; then
  printf '\033[1;33m    WARNING: %s/%s regional vCPUs free, %s nodes need %s.\n' \
    "$((LIMIT - USED))" "$LIMIT" "$MAX_NODES" "$NEED"
  printf '    T9 will stall. Request a quota increase, pick another LOCATION, or lower MAX_NODES.\033[0m\n'
fi

step "terraform apply (resource group, AKS with node pool 2-$MAX_NODES, registry)"
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve \
  -var "subscription_id=$SUBSCRIPTION_ID" \
  -var "location=$LOCATION" \
  -var "max_nodes=$MAX_NODES" \
  ${CI_PRINCIPAL_ID:+-var "ci_principal_id=$CI_PRINCIPAL_ID"} \
  ${BUDGET_EMAIL:+-var "budget_email=$BUDGET_EMAIL"}

IMAGE_REPO=$(terraform output -raw image_repository)
ACR_NAME=$(terraform output -raw acr_name)

step "kubectl credentials"
eval "$(terraform output -raw get_credentials)"

step "build and push $IMAGE_REPO:$TAG"
az acr login --name "$ACR_NAME"
# AKS nodes are amd64; building for it explicitly keeps an Apple-silicon
# laptop from pushing an image the nodes cannot run.
docker build --platform linux/amd64 -t "$IMAGE_REPO:$TAG" "$ROOT/app"
docker push "$IMAGE_REPO:$TAG"

step "ingress-nginx (external LoadBalancer)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null
# Azure's load balancer health-probes "/" by default, which ingress-nginx
# answers with 404, so the LB marks every node down and drops all traffic.
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set 'controller.service.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path=/healthz' \
  --wait --timeout 10m

if [ "$MONITORING" = 1 ]; then
  step "kube-prometheus-stack, dashboard, alert rules"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f "$ROOT/observability/values-kube-prometheus-stack.yaml" --wait --timeout 15m
  kubectl create configmap autoheal-dashboard -n monitoring \
    --from-file="$ROOT/observability/grafana-dashboard.json" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label configmap autoheal-dashboard -n monitoring grafana_dashboard=1 --overwrite
  kubectl apply -f "$ROOT/observability/alert-rules.yaml"
fi

# AKS ships metrics-server, so unlike kind nothing extra is needed for the HPA.
step "autoheal app"
helm upgrade --install autoheal "$ROOT/helm/autoheal-api" \
  --set image.repository="$IMAGE_REPO" \
  --set image.tag="$TAG" \
  --set serviceMonitor.enabled="$([ "$MONITORING" = 1 ] && echo true || echo false)" \
  --wait --timeout 10m

step "waiting for the load balancer IP"
for _ in $(seq 1 60); do
  IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "$IP" ] && break
  sleep 5
done
: "${IP:?no external IP after 5 minutes}"

# The LB health probe needs a few rounds to mark nodes healthy.
for _ in $(seq 1 24); do
  curl -sf -H "Host: autoheal.local" "http://$IP/healthz" && echo && break
  sleep 5
done
cat <<EOF

Ready. Load tests from this machine go through the cloud load balancer:

  export BASE_URL=http://$IP K6_NETWORK=bridge
  bash chaos/t9-cluster-autoscaler.sh     # T9
  bash chaos/t5-t6-autoscale.sh           # T5/T6
  bash chaos/run-all.sh                   # T1-T8

Tear down the same day:  bash infra/aks/down.sh
EOF
