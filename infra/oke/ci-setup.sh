#!/usr/bin/env bash
# One-time setup that lets GitHub Actions deploy to OKE, and lets the
# in-cluster cluster-autoscaler resize the node pool.
#
#   bash infra/oke/ci-setup.sh
#
# OCI has no OIDC/workload-identity federation for GitHub Actions as simple as
# Azure/GCP's, so the CI identity is a dedicated IAM user with an API signing
# key (rotate it by re-running this script). It gets no roles here: up.sh's
# Terraform grants the group access scoped to the compartment it creates, so
# the identity has nothing while the cluster is down.
#
# The cluster-autoscaler instead uses instance-principal auth (no static key):
# this script creates a dynamic group matching the node pool's instances and
# a policy letting them manage the node pool's underlying instance pool.
#
# Kept out of Terraform so the user, its key, and the dynamic group survive
# down.sh. Safe to re-run except for the key, which is only printed once.
set -euo pipefail

: "${COMPARTMENT_OCID:?set COMPARTMENT_OCID (same value passed to up.sh)}"
USER_NAME="${USER_NAME:-github-autoheal-deploy}"
GROUP_NAME="${GROUP_NAME:-github-autoheal-deploy}"
DYNAMIC_GROUP_NAME="${DYNAMIC_GROUP_NAME:-autoheal-node-pool}"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

TENANCY_OCID=$(oci iam compartment list --compartment-id-in-subtree false --all \
  --query 'data[0]."compartment-id"' --raw-output 2>/dev/null || \
  grep '^tenancy' "$HOME/.oci/config" | cut -d= -f2 | tr -d ' \r')

step "IAM user $USER_NAME"
USER_ID=$(oci iam user list --compartment-id "$TENANCY_OCID" --name "$USER_NAME" \
  --query 'data[0].id' --raw-output)
if [ "$USER_ID" = "null" ] || [ -z "$USER_ID" ]; then
  USER_ID=$(oci iam user create --compartment-id "$TENANCY_OCID" --name "$USER_NAME" \
    --description "GitHub Actions deploy identity for autoheal-k8s" --query 'data.id' --raw-output)
fi

step "group $GROUP_NAME"
GROUP_ID=$(oci iam group list --compartment-id "$TENANCY_OCID" --name "$GROUP_NAME" \
  --query 'data[0].id' --raw-output)
if [ "$GROUP_ID" = "null" ] || [ -z "$GROUP_ID" ]; then
  GROUP_ID=$(oci iam group create --compartment-id "$TENANCY_OCID" --name "$GROUP_NAME" \
    --description "Scoped by infra/oke's Terraform policy to the autoheal compartment only" \
    --query 'data.id' --raw-output)
fi
oci iam group add-user --group-id "$GROUP_ID" --user-id "$USER_ID" 2>/dev/null || true

step "API signing key (printed once -- save it now)"
KEY_DIR=$(mktemp -d)
openssl genrsa -out "$KEY_DIR/oci_api_key.pem" 2048 2>/dev/null
openssl rsa -pubout -in "$KEY_DIR/oci_api_key.pem" -out "$KEY_DIR/oci_api_key_public.pem" 2>/dev/null
FINGERPRINT=$(oci iam user api-key upload --user-id "$USER_ID" \
  --key-file "$KEY_DIR/oci_api_key_public.pem" --query 'data.fingerprint' --raw-output)

step "OCIR auth token (separate from the API key; docker login needs this one)"
AUTH_TOKEN=$(oci iam auth-token create --user-id "$USER_ID" \
  --description "OCIR docker login for autoheal-k8s CI" --query 'data.token' --raw-output)

step "dynamic group $DYNAMIC_GROUP_NAME (matches this compartment's node pool instances)"
DG_ID=$(oci iam dynamic-group list --compartment-id "$TENANCY_OCID" --name "$DYNAMIC_GROUP_NAME" \
  --query 'data[0].id' --raw-output)
if [ "$DG_ID" = "null" ] || [ -z "$DG_ID" ]; then
  DG_ID=$(oci iam dynamic-group create --compartment-id "$TENANCY_OCID" --name "$DYNAMIC_GROUP_NAME" \
    --description "OKE node pool instances for autoheal-k8s" \
    --matching-rule "ALL {instance.compartment.id = '$COMPARTMENT_OCID'}" \
    --query 'data.id' --raw-output)
fi

step "policy letting $DYNAMIC_GROUP_NAME resize its own node pool"
POLICY_NAME="${DYNAMIC_GROUP_NAME}-policy"
if ! oci iam policy list --compartment-id "$COMPARTMENT_OCID" --name "$POLICY_NAME" \
  --query 'data[0].id' --raw-output | grep -qv null; then
  oci iam policy create --compartment-id "$COMPARTMENT_OCID" --name "$POLICY_NAME" \
    --description "Cluster Autoscaler: resize the autoheal node pool" \
    --statements "[\"Allow dynamic-group $DYNAMIC_GROUP_NAME to manage instance-family in compartment id $COMPARTMENT_OCID\", \"Allow dynamic-group $DYNAMIC_GROUP_NAME to manage cluster-node-pools in compartment id $COMPARTMENT_OCID\"]" \
    >/dev/null
fi

cat <<EOF

Done. Bring the cluster up with CI access:

  COMPARTMENT_OCID=$COMPARTMENT_OCID CI_GROUP_NAME=$GROUP_NAME bash infra/oke/up.sh

Then add these as GitHub repository secrets/variables
(Settings > Secrets and variables > Actions):

  Secrets:
    OCI_CLI_USER            $USER_ID
    OCI_CLI_TENANCY         $TENANCY_OCID
    OCI_CLI_FINGERPRINT     $FINGERPRINT
    OCI_CLI_KEY_CONTENT     <contents of $KEY_DIR/oci_api_key.pem, then delete the file>
    OCIR_AUTH_TOKEN         $AUTH_TOKEN

  Variables:
    OCI_CLI_REGION          <region, e.g. us-ashburn-1>
    OCI_COMPARTMENT_OCID    $COMPARTMENT_OCID
    OCI_CLUSTER             autoheal (or your CLUSTER_NAME)
    OCI_USER_NAME           $USER_NAME
    OKE_DEPLOY              true      (set to false, or delete, while the cluster is down)

Private key is at $KEY_DIR/oci_api_key.pem -- copy it into the GitHub secret
now, then delete the directory: rm -rf $KEY_DIR
EOF
