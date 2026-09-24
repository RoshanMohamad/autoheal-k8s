#!/usr/bin/env bash
# Tears down everything infra/gke/up.sh created.
#
#   PROJECT_ID=my-project bash infra/gke/down.sh
#
# The ingress-nginx LoadBalancer (forwarding rule, external IP, firewall rules)
# was created by Kubernetes, not Terraform, so deleting the cluster alone can
# leave it behind and still billing. It is removed first, while the cluster
# that owns it still exists.
set -uo pipefail
cd "$(dirname "$0")"

: "${PROJECT_ID:?set PROJECT_ID}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

if kubectl get ns ingress-nginx >/dev/null 2>&1; then
  step "removing ingress-nginx and its cloud load balancer"
  helm uninstall ingress-nginx -n ingress-nginx --wait --timeout 5m
  # Deleting the Service releases the forwarding rule asynchronously; give the
  # service controller time to finish before its cluster disappears.
  for _ in $(seq 1 36); do
    kubectl -n ingress-nginx get svc ingress-nginx-controller >/dev/null 2>&1 || break
    sleep 5
  done
fi

step "terraform destroy"
terraform destroy -input=false -auto-approve \
  -var "project_id=$PROJECT_ID" \
  ${BILLING_ACCOUNT:+-var "billing_account=$BILLING_ACCOUNT"}

step "checking for leftover billable resources"
gcloud compute forwarding-rules list --project "$PROJECT_ID" --format='value(name,region)'
gcloud compute addresses list --project "$PROJECT_ID" --format='value(name,region,status)'
gcloud compute disks list --project "$PROJECT_ID" --format='value(name,zone)'
echo "(empty lists above mean nothing is left running)"
