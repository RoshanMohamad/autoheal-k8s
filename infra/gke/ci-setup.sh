#!/usr/bin/env bash
# One-time setup that lets GitHub Actions deploy to GKE without a key file.
#
#   PROJECT_ID=my-project GITHUB_REPO=owner/repo bash infra/gke/ci-setup.sh
#
# Creates a Workload Identity Federation pool trusted only for GITHUB_REPO and
# a deploy service account that can push images and deploy to the cluster.
# Kept out of Terraform on purpose: the pool must outlive down.sh, because a
# deleted pool's name stays reserved for 30 days and would block the next up.
# Safe to re-run. Costs nothing.
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
: "${GITHUB_REPO:?set GITHUB_REPO (owner/repo)}"
POOL=github
PROVIDER=github
SA_NAME=github-deploy
SA="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

gcloud config set project "$PROJECT_ID" >/dev/null
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

step "APIs"
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com

step "workload identity pool and GitHub OIDC provider"
gcloud iam workload-identity-pools describe "$POOL" --location=global >/dev/null 2>&1 ||
  gcloud iam workload-identity-pools create "$POOL" --location=global \
    --display-name="GitHub Actions"
gcloud iam workload-identity-pools providers describe "$PROVIDER" \
  --location=global --workload-identity-pool="$POOL" >/dev/null 2>&1 ||
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --location=global --workload-identity-pool="$POOL" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository == '$GITHUB_REPO'"

step "deploy service account $SA"
gcloud iam service-accounts describe "$SA" >/dev/null 2>&1 ||
  gcloud iam service-accounts create "$SA_NAME" --display-name="GitHub Actions deploy"
for role in roles/artifactregistry.writer roles/container.developer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA" --role="$role" --condition=None >/dev/null
done
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL/attribute.repository/$GITHUB_REPO" \
  >/dev/null

cat <<EOF

Done. Add these as GitHub repository variables
(Settings > Secrets and variables > Actions > Variables):

  GCP_PROJECT_ID     $PROJECT_ID
  GCP_WIF_PROVIDER   projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL/providers/$PROVIDER
  GCP_DEPLOY_SA      $SA
  GKE_DEPLOY         true      (set to false, or delete, while the cluster is down)

Optional, only if you changed them in terraform.tfvars:
  GCP_REGION (default us-central1), GKE_ZONE (default us-central1-a),
  GKE_CLUSTER (default autoheal)
EOF
