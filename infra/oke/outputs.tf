output "cluster_id" {
  value = oci_containerengine_cluster.this.id
}

output "cluster_name" {
  value = oci_containerengine_cluster.this.name
}

output "compartment_ocid" {
  value = var.compartment_ocid
}

output "node_pool_id" {
  value = oci_containerengine_node_pool.this.id
}

output "registry_namespace" {
  description = "Tenancy namespace OCIR image paths are built from."
  value       = data.oci_objectstorage_namespace.this.namespace
}

output "image_repository" {
  description = "Push the app image here; pass it to Helm as image.repository. <region-key>.ocir.io, e.g. iad.ocir.io for us-ashburn-1."
  value       = "${var.region}.ocir.io/${data.oci_objectstorage_namespace.this.namespace}/autoheal-api"
}

output "get_credentials" {
  value = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.this.id} --file $HOME/.kube/config --region ${var.region} --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT"
}

output "min_nodes" {
  value = var.min_nodes
}

output "max_nodes" {
  value = var.max_nodes
}

output "node_shape" {
  value = var.node_shape
}

output "region" {
  value = var.region
}
