#!/usr/bin/env bash
# Week 6: creates the GKE cluster and deploys everything onto it.
#
#   PROJECT_ID=my-project bash infra/gke/up.sh
#   PROJECT_ID=my-project BILLING_ACCOUNT=XXXXXX-XXXXXX-XXXXXX bash infra/gke/up.sh
#
# Prerequisites: gcloud (logged in: `gcloud auth login` and
# `gcloud auth application-default login`), the gke-gcloud-auth-plugin
# component, terraform, helm, kubectl, docker.
#
# Costs money from the moment it finishes. Tear down with infra/gke/down.sh.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..

: "${PROJECT_ID:?set PROJECT_ID}"
MONITORING="${MONITORING:-1}"
TAG="${TAG:-$(git rev-parse --short HEAD)}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "terraform apply (cluster, node pool 2-4, registry, node service account)"
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve \
  -var "project_id=$PROJECT_ID" \
  ${BILLING_ACCOUNT:+-var "billing_account=$BILLING_ACCOUNT"}

IMAGE_REPO=$(terraform output -raw image_repository)
REGISTRY_HOST=${IMAGE_REPO%%/*}

step "kubectl credentials"
eval "$(terraform output -raw get_credentials)"

step "build and push $IMAGE_REPO:$TAG"
gcloud auth configure-docker "$REGISTRY_HOST" --quiet >/dev/null
# GKE nodes are amd64; building for it explicitly keeps an Apple-silicon
# laptop from pushing an image the nodes cannot run.
docker build --platform linux/amd64 -t "$IMAGE_REPO:$TAG" "$ROOT/app"
docker push "$IMAGE_REPO:$TAG"

step "ingress-nginx (external LoadBalancer)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace --wait --timeout 10m

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

# GKE ships metrics-server, so unlike kind nothing extra is needed for the HPA.
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

curl -sf -H "Host: autoheal.local" "http://$IP/healthz" && echo
cat <<EOF

Ready. Load tests from this machine go through the cloud load balancer:

  export BASE_URL=http://$IP K6_NETWORK=bridge
  bash chaos/t9-cluster-autoscaler.sh     # T9
  bash chaos/t5-t6-autoscale.sh           # T5/T6
  bash chaos/run-all.sh                   # T1-T8

Tear down the same day:  PROJECT_ID=$PROJECT_ID bash infra/gke/down.sh
EOF
