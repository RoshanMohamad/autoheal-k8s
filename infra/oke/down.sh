#!/usr/bin/env bash
# Tears down everything infra/oke/up.sh created.
#
#   bash infra/oke/down.sh
#
# ingress-nginx's OCI Load Balancer is created by Kubernetes, not Terraform,
# so it is removed first -- otherwise `terraform destroy` can leave it (and
# its public IP) behind and still billing.
set -uo pipefail
cd "$(dirname "$0")"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

COMPARTMENT_OCID=$(terraform output -raw compartment_ocid 2>/dev/null)
REGION=$(terraform output -raw region 2>/dev/null)

if kubectl get ns ingress-nginx >/dev/null 2>&1; then
  step "removing ingress-nginx and its load balancer"
  helm uninstall ingress-nginx -n ingress-nginx --wait --timeout 5m
fi

if kubectl get ns kube-system >/dev/null 2>&1; then
  step "removing the cluster-autoscaler"
  helm uninstall cluster-autoscaler -n kube-system --wait --timeout 5m 2>/dev/null || true
fi

step "terraform destroy"
terraform destroy -input=false -auto-approve \
  ${COMPARTMENT_OCID:+-var "compartment_ocid=$COMPARTMENT_OCID"} \
  ${REGION:+-var "region=$REGION"}

step "checking for leftover billable resources"
if [ -n "$COMPARTMENT_OCID" ]; then
  oci lb load-balancer list --compartment-id "$COMPARTMENT_OCID" \
    --query "data[?contains(\"display-name\",'ingress-nginx')].{name:\"display-name\",id:id}" -o table 2>/dev/null
  oci compute instance list --compartment-id "$COMPARTMENT_OCID" \
    --lifecycle-state RUNNING --query "data[].{name:\"display-name\"}" -o table 2>/dev/null
  oci network public-ip list --compartment-id "$COMPARTMENT_OCID" --scope REGION \
    --query "data[?\"lifecycle-state\"=='ASSIGNED'].{ip:\"ip-address\"}" -o table 2>/dev/null
fi
echo "(no rows in the tables above means nothing is left running)"
