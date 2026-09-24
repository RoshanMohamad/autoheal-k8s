variable "subscription_id" {
  description = "Azure subscription to create everything in."
  type        = string
}

variable "location" {
  description = "Azure region. Student and free-trial subscriptions may only allow some regions, and each region has its own vCPU quota."
  type        = string
  default     = "eastus"
}

variable "resource_group" {
  description = "Resource group holding the cluster and registry. Deleted by down.sh."
  type        = string
  default     = "autoheal-rg"
}

variable "cluster_name" {
  type    = string
  default = "autoheal"
}

variable "vm_size" {
  description = "Standard_D2s_v5 (2 vCPU, 8 GB) fits the app, ingress-nginx and kube-prometheus-stack on 2 nodes. Burstable B-series is cheaper but runs out of CPU credits under load, which skews the HPA tests."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "min_nodes" {
  type    = number
  default = 2
}

variable "max_nodes" {
  description = "Hard cap on the Cluster Autoscaler: the main cost control. max_nodes x 2 vCPU must fit the region's vCPU quota."
  type        = number
  default     = 4
}

variable "ci_principal_id" {
  description = "Object ID of the GitHub Actions service principal from ci-setup.sh. If set, it gets push access to the registry and user access to the cluster. Leave empty to skip."
  type        = string
  default     = ""
}

variable "budget_email" {
  description = "If set, a monthly budget on the resource group emails this address at 50/90/100%. Leave empty to skip."
  type        = string
  default     = ""
}

variable "budget_amount" {
  description = "Monthly budget in the subscription's billing currency."
  type        = number
  default     = 10
}
