#!/usr/bin/env bash
# Week 6: creates the OKE cluster and deploys everything onto it.
#
#   COMPARTMENT_OCID=ocid1.compartment.oc1..xxx bash infra/oke/up.sh
#   LOCATION=eu-frankfurt-1 MAX_NODES=3 bash infra/oke/up.sh
#
# Reads tenancy/user/fingerprint/key from ~/.oci/config (`oci setup config`)
# unless OCI_CLI_* env vars are set. CI_GROUP_NAME (default
# github-autoheal-deploy, printed by ci-setup.sh) gets a policy scoped to this
# compartment; set it to "" to skip.
#
# Prerequisites: oci CLI (`oci setup config`), terraform, helm, kubectl, docker.
#
# Costs money from the moment it finishes (unless everything fits the Always
# Free A1.Flex/OCPU allowance). Tear down with infra/oke/down.sh.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..

: "${COMPARTMENT_OCID:?set COMPARTMENT_OCID (oci iam compartment list, or the tenancy OCID from ~/.oci/config for a fresh account)}"
REGION="${LOCATION:-$(oci iam region-subscription list --query 'data[0]."region-name"' --raw-output)}"
MAX_NODES="${MAX_NODES:-4}"
MONITORING="${MONITORING:-1}"
CI_GROUP_NAME="${CI_GROUP_NAME-github-autoheal-deploy}"
TAG="${TAG:-$(git rev-parse --short HEAD)}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "terraform apply (VCN, OKE cluster, node pool 2-$MAX_NODES)"
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve \
  -var "compartment_ocid=$COMPARTMENT_OCID" \
  -var "region=$REGION" \
  -var "max_nodes=$MAX_NODES" \
  -var "ci_group_name=$CI_GROUP_NAME"

IMAGE_REPO=$(terraform output -raw image_repository)
CLUSTER_ID=$(terraform output -raw cluster_id)
NODE_POOL_ID=$(terraform output -raw node_pool_id)
MIN_NODES=$(terraform output -raw min_nodes)

step "kubectl credentials"
mkdir -p "$HOME/.kube"
oci ce cluster create-kubeconfig --cluster-id "$CLUSTER_ID" --file "$HOME/.kube/config" \
  --region "$REGION" --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT

step "waiting for nodes to join"
for _ in $(seq 1 60); do
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ') || true
  [ "${READY:-0}" -ge "$MIN_NODES" ] && break
  sleep 10
done

step "build and push $IMAGE_REPO:$TAG"
REGION_KEY=$(oci iam region list --query "data[?name=='$REGION'].key | [0]" --raw-output | tr 'A-Z' 'a-z')
echo "    docker login to $REGION_KEY.ocir.io needed once; see infra/oke/ci-setup.sh or"
echo "    https://docs.oracle.com/iaas/Content/Registry/Tasks/registrypushingimagesusingthedockercli.htm"
docker login "$REGION_KEY.ocir.io" || true
# OKE nodes are amd64 by default (node_shape = VM.Standard.E4.Flex); building
# for it explicitly keeps an Apple-silicon laptop from pushing an image the
# nodes cannot run.
docker build --platform linux/amd64 -t "$IMAGE_REPO:$TAG" "$ROOT/app"
docker push "$IMAGE_REPO:$TAG"

step "ingress-nginx (OCI Load Balancer)"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --wait --timeout 10m

step "cluster-autoscaler (OCI provider, node pool $NODE_POOL_ID)"
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null 2>&1 || true
helm repo update autoscaler >/dev/null
# Uses each node's instance-principal identity (granted by ci-setup.sh's
# dynamic group + policy) instead of a long-lived key, so nothing to rotate.
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set cloudProvider=oci \
  --set autoDiscovery.clusterName="$(terraform output -raw cluster_name)" \
  --set "extraArgs.nodes[0]=$MIN_NODES:$MAX_NODES:$NODE_POOL_ID" \
  --wait --timeout 5m

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

step "metrics-server (not preinstalled on OKE, unlike AKS/GKE)"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
helm repo update metrics-server >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --wait

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

Tear down the same day:  bash infra/oke/down.sh
EOF
