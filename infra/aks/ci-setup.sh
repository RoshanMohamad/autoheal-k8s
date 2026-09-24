#!/usr/bin/env bash
# One-time setup that lets GitHub Actions deploy to AKS without a client secret.
#
#   GITHUB_REPO=owner/repo bash infra/aks/ci-setup.sh
#
# Creates an Entra ID app registration with a federated credential trusted only
# for pushes to main in GITHUB_REPO. It gets no roles here: up.sh passes its
# object ID to Terraform, which grants access scoped to the registry and
# cluster it creates, so the identity has nothing while the cluster is down.
# Kept out of Terraform so the app, and its IDs in GitHub, survive down.sh.
# Safe to re-run. Costs nothing.
set -euo pipefail

: "${GITHUB_REPO:?set GITHUB_REPO (owner/repo)}"
APP_NAME="${APP_NAME:-github-autoheal-deploy}"
BRANCH="${BRANCH:-main}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# Strips the \r the Windows az CLI adds to every line under Git Bash.
az() { command az "$@" | tr -d '\r'; }

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

step "app registration $APP_NAME"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)
[ -n "$APP_ID" ] || APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)

step "service principal"
SP_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null ||
  az ad sp create --id "$APP_ID" --query id -o tsv)

step "federated credential for $GITHUB_REPO@$BRANCH"
SUBJECT="repo:$GITHUB_REPO:ref:refs/heads/$BRANCH"
if ! az ad app federated-credential list --id "$APP_ID" --query "[].subject" -o tsv | grep -qx "$SUBJECT"; then
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"github-${BRANCH//\//-}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$SUBJECT\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" >/dev/null
fi

cat <<EOF

Done. Bring the cluster up with CI access:

  CI_PRINCIPAL_ID=$SP_ID bash infra/aks/up.sh

Then add these as GitHub repository variables
(Settings > Secrets and variables > Actions > Variables):

  AZURE_CLIENT_ID        $APP_ID
  AZURE_TENANT_ID        $TENANT_ID
  AZURE_SUBSCRIPTION_ID  $SUBSCRIPTION_ID
  ACR_NAME               <terraform -chdir=infra/aks output -raw acr_name>
  AKS_DEPLOY             true      (set to false, or delete, while the cluster is down)

Optional, only if you changed them:
  AKS_RESOURCE_GROUP (default autoheal-rg), AKS_CLUSTER (default autoheal)
EOF
