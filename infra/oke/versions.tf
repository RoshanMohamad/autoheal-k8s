terraform {
  required_version = ">= 1.5"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.0"
    }
  }
}

# Reads ~/.oci/config (written by `oci setup config`) for tenancy, user,
# fingerprint, key and region, the same way up.sh's azurerm/google
# counterparts pick up `az login` / `gcloud auth`. CI overrides all of these
# with OCI_CLI_* env vars via oracle-actions/configure-ociauth.
#
# auth is pinned to "ApiKey" rather than left to provider auto-detection:
# OCI Cloud Shell exports resource-principal env vars ambiently, which can
# make the provider try (and fail) resource-principal auth instead of the
# config file even though `oci setup config` has already written one.
provider "oci" {
  auth                = var.oci_auth
  config_file_profile = var.oci_profile
  region              = var.region
}
