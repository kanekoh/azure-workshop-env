# ARO Cluster
resource "azurerm_redhat_openshift_cluster" "aro" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  domain              = var.domain != "" ? var.domain : null

  master_node {
    vm_size   = var.master_vm_size
    disk_size = var.master_disk_size
  }

  worker_node {
    vm_size   = var.worker_vm_size
    disk_size = var.worker_disk_size
    count     = var.worker_count
  }

  network_profile {
    pod_cidr     = var.pod_cidr
    service_cidr = var.service_cidr
  }

  # Use subnets from network phase
  master_subnet_id = var.master_subnet_id
  worker_subnet_id = var.worker_subnet_id

  # Pull secret (if provided)
  pull_secret = var.pull_secret != "" ? var.pull_secret : null

  tags = var.tags
}
