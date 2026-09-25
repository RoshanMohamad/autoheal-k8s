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
provider "oci" {
  region = var.region
}
