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
  description = "VM.Standard.A1.Flex (Ampere/arm64) is Always Free up to 4 OCPU/24GB total per tenancy -- the default here, sized so min_nodes/max_nodes stay inside that. up.sh builds the app image for arm64 to match. Switch to VM.Standard.E4.Flex (AMD, pay-as-you-go) for a bigger/x86 cluster."
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "node_ocpus" {
  description = "OCPUs per node (flex shape). At the defaults, max_nodes x this must stay <= 4 to fit the Always Free A1.Flex allowance."
  type        = number
  default     = 1
}

variable "node_memory_gbs" {
  description = "Memory (GB) per node. At the defaults, max_nodes x this must stay <= 24 to fit the Always Free A1.Flex allowance."
  type        = number
  default     = 6
}

variable "boot_volume_size_in_gbs" {
  description = "Per-node boot volume. Always Free includes 200 GB of total block storage, so max_nodes x this must stay well under that (defaults: 4 x 50 = 200 GB, i.e. no headroom -- lower this or max_nodes if the compartment has other volumes)."
  type        = number
  default     = 50
}

variable "min_nodes" {
  type    = number
  default = 2
}

variable "max_nodes" {
  description = "Hard cap on the Cluster Autoscaler: the main cost/quota control. See node_ocpus, node_memory_gbs and boot_volume_size_in_gbs for how this interacts with the Always Free allowance."
  type        = number
  default     = 4
}

variable "ci_group_name" {
  description = "IAM group ci-setup.sh creates for the GitHub Actions user. Given a policy scoped to this compartment only, so it does nothing while the cluster is down."
  type        = string
  default     = "github-autoheal-deploy"
}
