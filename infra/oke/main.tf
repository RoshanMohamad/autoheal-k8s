data "oci_identity_availability_domains" "this" {
  compartment_id = var.compartment_ocid
}

# ---------------------------------------------------------------- networking

# A single public VCN: simplest setup that still gives every OKE component
# (API endpoint, worker nodes, load balancer) internet reachability, matching
# the "quick create" topology OCI's own console uses for test clusters. No
# NAT/service gateway, so there is nothing else to pay for or clean up.
resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.cluster_name}-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = "autoheal"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-igw"
}

resource "oci_core_default_route_table" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_route_table_id
  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

# One permissive security list for the whole VCN: allow all traffic between
# cluster components, plus the k8s API (6443), NodePort range, and 80/443 for
# the ingress-nginx load balancer, from the internet. Good enough for a
# throwaway test cluster; tighten with NSGs for anything longer-lived.
resource "oci_core_security_list" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.cluster_name}-seclist"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "all"
    source   = var.vcn_cidr
  }

  dynamic "ingress_security_rules" {
    for_each = [6443, 80, 443]
    content {
      protocol = "6"
      source   = "0.0.0.0/0"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_subnet" "k8s_api" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "${var.cluster_name}-k8s-api"
  cidr_block                 = cidrsubnet(var.vcn_cidr, 12, 0)
  route_table_id             = oci_core_vcn.this.default_route_table_id
  security_list_ids          = [oci_core_security_list.this.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_subnet" "nodes" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "${var.cluster_name}-nodes"
  cidr_block                 = cidrsubnet(var.vcn_cidr, 4, 1)
  route_table_id             = oci_core_vcn.this.default_route_table_id
  security_list_ids          = [oci_core_security_list.this.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_subnet" "lb" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "${var.cluster_name}-lb"
  cidr_block                 = cidrsubnet(var.vcn_cidr, 8, 8)
  route_table_id             = oci_core_vcn.this.default_route_table_id
  security_list_ids          = [oci_core_security_list.this.id]
  prohibit_public_ip_on_vnic = false
}

# ------------------------------------------------------------------ registry

# OCIR is one registry per region per tenancy namespace; no resource to
# create, just a policy letting the CI user push to it (see below).
data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_ocid
}

# ----------------------------------------------------------------- cluster

data "oci_containerengine_cluster_option" "this" {
  cluster_option_id = "all"
}

resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_ocid
  name               = var.cluster_name
  vcn_id             = oci_core_vcn.this.id
  kubernetes_version = element(data.oci_containerengine_cluster_option.this.kubernetes_versions, length(data.oci_containerengine_cluster_option.this.kubernetes_versions) - 1)
  type               = "BASIC_CLUSTER"

  endpoint_config {
    subnet_id            = oci_core_subnet.k8s_api.id
    is_public_ip_enabled = true
    nsg_ids              = []
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.lb.id]

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }
  }
}

resource "oci_containerengine_node_pool" "this" {
  compartment_id     = var.compartment_ocid
  cluster_id         = oci_containerengine_cluster.this.id
  name               = "${var.cluster_name}-pool"
  kubernetes_version = oci_containerengine_cluster.this.kubernetes_version
  node_shape         = var.node_shape

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gbs
  }

  node_source_details {
    source_type = "IMAGE"
    image_id    = [for s in data.oci_containerengine_node_pool_option.this.sources : s.image_id if length(regexall("OKE-", s.source_name)) > 0][0]
  }

  node_config_details {
    size = var.min_nodes

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.this.availability_domains[0].name
      subnet_id           = oci_core_subnet.nodes.id
    }
  }

  initial_node_labels {
    key   = "autoheal.io/pool"
    value = "primary"
  }

  # Read by up.sh to build the Cluster Autoscaler's --nodes=min:max:poolID
  # flag -- OKE has no built-in min/max toggle like AKS/GKE, so the
  # community autoscaler (deployed by up.sh) resizes node_config_details.size
  # on this pool directly via the OCI API.
  freeform_tags = {
    "min-nodes" = tostring(var.min_nodes)
    "max-nodes" = tostring(var.max_nodes)
  }
}

data "oci_containerengine_node_pool_option" "this" {
  # Scoped to this cluster so the image list matches its Kubernetes version,
  # rather than "all", which lists every OKE image ever published.
  node_pool_option_id = oci_containerengine_cluster.this.id
  compartment_id      = var.compartment_ocid
}

# ---------------------------------------------------------------------- CI

# The IAM user, group and API key live outside Terraform (ci-setup.sh), the
# same way the AKS/GKE variants keep the CI identity out of Terraform so it
# survives down.sh. This policy only grants that group access scoped to this
# compartment, recreated on every up.sh, so it has nothing while the cluster
# is down.
resource "oci_identity_policy" "ci" {
  count          = var.ci_group_name == "" ? 0 : 1
  compartment_id = var.compartment_ocid
  name           = "${var.cluster_name}-ci-policy"
  description    = "Scoped access for the GitHub Actions deploy job."
  statements = [
    "Allow group ${var.ci_group_name} to manage repos in compartment id ${var.compartment_ocid}",
    "Allow group ${var.ci_group_name} to use cluster-family in compartment id ${var.compartment_ocid}",
  ]
}
