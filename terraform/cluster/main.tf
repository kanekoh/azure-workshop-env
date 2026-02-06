# Service Principal for ARO (if not provided, create one)
data "azurerm_client_config" "current" {}

# ARO Cluster
resource "azurerm_redhat_openshift_cluster" "aro" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name

  cluster_profile {
    domain          = var.domain
    pull_secret     = var.pull_secret != "" ? var.pull_secret : null
    version         = var.ocp_version
    fips_enabled    = false
  }

  main_profile {
    vm_size   = var.master_vm_size
    subnet_id = var.master_subnet_id
    disk_encryption_set_id = null
    encryption_at_host_enabled = false
  }

  worker_profile {
    vm_size     = var.worker_vm_size
    subnet_id   = var.worker_subnet_id
    disk_size_gb = var.worker_disk_size
    disk_encryption_set_id = null
    encryption_at_host_enabled = false
    node_count  = var.worker_count
  }

  service_principal {
    client_id     = data.azurerm_client_config.current.client_id
    client_secret = var.service_principal_client_secret
  }

  api_server_profile {
    visibility = "Public"
  }

  ingress_profile {
    visibility = "Public"
  }

  network_profile {
    pod_cidr      = var.pod_cidr
    service_cidr  = var.service_cidr
    outbound_type = "Loadbalancer"
  }

  tags = var.tags
}
