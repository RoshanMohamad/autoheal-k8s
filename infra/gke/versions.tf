terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  # Budgets are billed against the billing account, not the project, and the
  # Billing Budget API refuses user credentials without a quota project.
  user_project_override = true
  billing_project       = var.project_id
}
