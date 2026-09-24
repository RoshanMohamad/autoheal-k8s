locals {
  apis = [
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "billingbudgets.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------- registry

resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "autoheal"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# ------------------------------------------------------------ node identity

# A dedicated, least-privilege node service account. The default compute SA is
# either over-privileged (Editor) or, in newer projects, has no roles at all and
# cannot pull from Artifact Registry.
resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE nodes for ${var.cluster_name}"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/artifactregistry.reader",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# ----------------------------------------------------------------- cluster

resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.zone

  # The default pool cannot be configured with autoscaling here; replace it
  # with the managed pool below.
  remove_default_node_pool = true
  initial_node_count       = 1

  # This is a throwaway test cluster that is destroyed the same day.
  deletion_protection = false

  release_channel {
    channel = "REGULAR"
  }

  # The Cluster Autoscaler's profile. OPTIMIZE_UTILIZATION removes idle nodes
  # sooner than BALANCED, which matters when paying by the node-hour.
  cluster_autoscaling {
    autoscaling_profile = "OPTIMIZE_UTILIZATION"
  }

  depends_on = [google_project_service.apis]
}

resource "google_container_node_pool" "default" {
  name     = "default"
  cluster  = google_container_cluster.this.name
  location = var.zone

  # Per-pool Cluster Autoscaler bounds (O8 / T9).
  autoscaling {
    min_node_count = var.min_nodes
    max_node_count = var.max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.machine_type
    disk_size_gb    = 30
    disk_type       = "pd-standard"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

# ------------------------------------------------------------------ budget

resource "google_billing_budget" "this" {
  count           = var.billing_account == "" ? 0 : 1
  billing_account = var.billing_account
  display_name    = "${var.cluster_name} test budget"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      units = tostring(var.budget_amount)
    }
  }

  # Emails go to the billing account's admins by default.
  threshold_rules { threshold_percent = 0.5 }
  threshold_rules { threshold_percent = 0.9 }
  threshold_rules { threshold_percent = 1.0 }

  depends_on = [google_project_service.apis]
}

data "google_project" "this" {
  project_id = var.project_id
}
