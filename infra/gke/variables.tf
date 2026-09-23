variable "project_id" {
  description = "GCP project to create everything in. Must have billing enabled."
  type        = string
}

variable "region" {
  description = "Region for the Artifact Registry repository."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the cluster. Zonal, not regional: GKE's free tier covers one zonal control plane, and a regional cluster would triple the nodes."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  type    = string
  default = "autoheal"
}

variable "machine_type" {
  description = "e2-standard-2 (2 vCPU, 8 GB) fits the app, ingress-nginx and kube-prometheus-stack on 2 nodes."
  type        = string
  default     = "e2-standard-2"
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

variable "billing_account" {
  description = "Billing account ID (XXXXXX-XXXXXX-XXXXXX). If set, a budget with email alerts is created. Leave empty to skip."
  type        = string
  default     = ""
}

variable "budget_amount" {
  description = "Monthly budget in the billing account's currency."
  type        = number
  default     = 10
}
