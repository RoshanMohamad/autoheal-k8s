output "cluster_name" {
  value = google_container_cluster.this.name
}

output "zone" {
  value = var.zone
}

output "image_repository" {
  description = "Push the app image here; pass it to Helm as image.repository."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}/autoheal-api"
}

output "get_credentials" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --zone ${var.zone} --project ${var.project_id}"
}
