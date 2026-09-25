variable "compartment_ocid" {
  description = "Compartment to create the VCN, cluster and node pool in. `oci iam compartment list` (or the root/tenancy OCID from ~/.oci/config for a fresh account)."
  type        = string
}

variable "region" {
  description = "OCI region, e.g. us-ashburn-1. Defaults to the region in ~/.oci/config if left empty."
  type        = string
  default     = ""
}

variable "cluster_name" {
  type    = string
  default = "autoheal"
}

variable "vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "node_shape" {
  description = "VM.Standard.E4.Flex is AMD, pay-as-you-go, covered by trial credits. VM.Standard.A1.Flex (Ampere/arm64) is Always Free up to 4 OCPU/24GB total in the tenancy, but the app image must then be built for arm64."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "node_ocpus" {
  description = "OCPUs per node (flex shape). 1 OCPU ~= 2 vCPUs, matching AKS's Standard_D2s_v5."
  type        = number
  default     = 1
}

variable "node_memory_gbs" {
  type    = number
  default = 8
}

variable "min_nodes" {
  type    = number
  default = 2
}

variable "max_nodes" {
  description = "Hard cap on the Cluster Autoscaler: the main cost control."
  type        = number
  default     = 4
}

variable "ci_group_name" {
  description = "IAM group ci-setup.sh creates for the GitHub Actions user. Given a policy scoped to this compartment only, so it does nothing while the cluster is down."
  type        = string
  default     = "github-autoheal-deploy"
}
