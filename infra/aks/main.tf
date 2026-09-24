resource "azurerm_resource_group" "this" {
  name     = var.resource_group
  location = var.location
}

# ---------------------------------------------------------------- registry

# Registry names are global across Azure. A suffix derived from the
# subscription avoids collisions yet stays the same across down/up, so the
# ACR_NAME GitHub variable does not need updating after every rebuild.
resource "azurerm_container_registry" "images" {
  name                = "autoheal${substr(sha1(var.subscription_id), 0, 8)}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  # Access goes through Entra ID role assignments, never a shared password.
  admin_enabled = false
}

# ----------------------------------------------------------------- cluster

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  dns_prefix          = var.cluster_name

  # Free tier: no control-plane fee and no uptime SLA, which is fine for a
  # throwaway test cluster.
  sku_tier = "Free"

  default_node_pool {
    name    = "default"
    vm_size = var.vm_size

    # Per-pool Cluster Autoscaler bounds (O8 / T9).
    auto_scaling_enabled = true
    min_count            = var.min_nodes
    max_count            = var.max_nodes

    os_disk_size_gb = 30
    os_disk_type    = "Managed"

    # Lets Terraform change vm_size by rotating to a temporary pool instead of
    # destroying the cluster.
    temporary_name_for_rotation = "tmp"

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    # Overlay gives pods addresses from a private range, not the VNet, so the
    # subnet cannot run out of IPs when the HPA and autoscaler scale out.
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
  }

  # "Manual" is the classic Cluster Autoscaler driven by the node pool's
  # min/max above; "Auto" would hand nodes to Karpenter-based autoprovisioning.
  node_provisioning_profile {
    mode = "Manual"
  }

  # Tuned like GKE's OPTIMIZE_UTILIZATION profile: idle nodes go after 5 min
  # instead of the default 10, which matters when paying by the node-hour.
  auto_scaler_profile {
    expander                         = "least-waste"
    scale_down_unneeded              = "5m"
    scale_down_delay_after_add       = "5m"
    scale_down_utilization_threshold = "0.5"
  }
}

# The kubelet's managed identity pulls images; no imagePullSecrets needed.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                            = azurerm_container_registry.images.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

# ---------------------------------------------------------------------- CI

# Scoped to this registry and cluster, and recreated on every up.sh, so the
# CI identity can do nothing while the cluster is down.
resource "azurerm_role_assignment" "ci" {
  for_each = var.ci_principal_id == "" ? {} : {
    acr_push     = { scope = azurerm_container_registry.images.id, role = "AcrPush" }
    acr_read     = { scope = azurerm_container_registry.images.id, role = "Reader" }
    cluster_user = { scope = azurerm_kubernetes_cluster.this.id, role = "Azure Kubernetes Service Cluster User Role" }
  }
  scope                            = each.value.scope
  role_definition_name             = each.value.role
  principal_id                     = var.ci_principal_id
  skip_service_principal_aad_check = true
}

# ------------------------------------------------------------------ budget

resource "azurerm_consumption_budget_resource_group" "this" {
  count             = var.budget_email == "" ? 0 : 1
  name              = "${var.cluster_name}-test-budget"
  resource_group_id = azurerm_resource_group.this.id
  amount            = var.budget_amount
  time_grain        = "Monthly"

  time_period {
    # Must be the first of a month; fixed at creation so later applies do not
    # try to move it.
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  dynamic "notification" {
    for_each = [50, 90, 100]
    content {
      enabled        = true
      threshold      = notification.value
      operator       = "GreaterThanOrEqualTo"
      threshold_type = "Actual"
      contact_emails = [var.budget_email]
    }
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}
