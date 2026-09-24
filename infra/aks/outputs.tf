output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "node_resource_group" {
  description = "Where AKS puts the VMs, disks and load balancer. Deleted with the cluster."
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "acr_name" {
  value = azurerm_container_registry.images.name
}

output "image_repository" {
  description = "Push the app image here; pass it to Helm as image.repository."
  value       = "${azurerm_container_registry.images.login_server}/autoheal-api"
}

output "get_credentials" {
  value = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_kubernetes_cluster.this.name} --overwrite-existing"
}
