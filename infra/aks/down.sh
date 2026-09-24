#!/usr/bin/env bash
# Tears down everything infra/aks/up.sh created.
#
#   bash infra/aks/down.sh
#
# Unlike GKE, the ingress-nginx load balancer and its public IP live in the
# cluster's node resource group (MC_...), which Azure deletes with the cluster.
# ingress-nginx is still removed first so nothing is mid-provisioning when the
# cluster goes, then the script checks that both resource groups are gone.
set -uo pipefail
cd "$(dirname "$0")"

# Strips the \r the Windows az CLI adds to every line under Git Bash.
az() { command az "$@" | tr -d '\r'; }

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

NODE_RG=$(terraform output -raw node_resource_group 2>/dev/null)
RG=$(terraform output -raw resource_group 2>/dev/null)

if kubectl get ns ingress-nginx >/dev/null 2>&1; then
  step "removing ingress-nginx and its load balancer rules"
  helm uninstall ingress-nginx -n ingress-nginx --wait --timeout 5m
fi

# Variables that only change resources (budget, CI access, node count) do not
# need to match up.sh; location and names do, and have the same defaults.
step "terraform destroy"
terraform destroy -input=false -auto-approve \
  -var "subscription_id=$SUBSCRIPTION_ID" \
  ${LOCATION:+-var "location=$LOCATION"}

step "checking for leftover billable resources"
for g in $RG $NODE_RG; do
  if [ "$(az group exists --name "$g" --subscription "$SUBSCRIPTION_ID")" = true ]; then
    echo "resource group $g still exists:"
    az resource list --resource-group "$g" --subscription "$SUBSCRIPTION_ID" --query '[].{name:name,type:type}' -o table
  fi
done
az network public-ip list --subscription "$SUBSCRIPTION_ID" --query "[?contains(resourceGroup, 'autoheal')].name" -o tsv
az disk list --subscription "$SUBSCRIPTION_ID" --query "[?contains(resourceGroup, 'autoheal')].name" -o tsv
echo "(no output above means nothing is left running)"
