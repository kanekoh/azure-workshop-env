# Check if resource group exists
data "azurerm_resource_group" "existing" {
  count = var.resource_group_create ? 0 : 1
  name  = var.resource_group_name
}

# Create resource group if it doesn't exist
resource "azurerm_resource_group" "main" {
  count    = var.resource_group_create ? 1 : 0
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# Use existing or created resource group
locals {
  resource_group_name     = var.resource_group_create ? azurerm_resource_group.main[0].name : data.azurerm_resource_group.existing[0].name
  resource_group_location = var.resource_group_create ? azurerm_resource_group.main[0].location : data.azurerm_resource_group.existing[0].location
}

# ARO resource provider service principal (Application ID is fixed)
data "azuread_service_principal" "aro_rp" {
  count  = var.aro_rp_service_principal_object_id == "" ? 1 : 0
  client_id = var.aro_rp_service_principal_client_id
}

locals {
  aro_rp_service_principal_object_id = var.aro_rp_service_principal_object_id != "" ? var.aro_rp_service_principal_object_id : data.azuread_service_principal.aro_rp[0].object_id
}

# Virtual Network
resource "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  address_space       = var.vnet_address_space
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

# Grant Network Contributor on VNet to ARO RP service principal
resource "azurerm_role_assignment" "aro_rp_network_contributor" {
  scope                = azurerm_virtual_network.main.id
  role_definition_name = "Network Contributor"
  principal_id         = local.aro_rp_service_principal_object_id
}

# Network Security Group for ARO
resource "azurerm_network_security_group" "aro" {
  name                = "aro-nsg"
  location            = local.resource_group_location
  resource_group_name = local.resource_group_name
  tags                = var.tags

  # Allow API server traffic (port 6443)
  security_rule {
    name                       = "AllowAPIServerInbound"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Allow API server traffic"
  }

  # Allow ingress traffic (ports 80, 443)
  security_rule {
    name                       = "AllowIngressInbound"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Allow ingress traffic"
  }

  # Allow all outbound traffic
  security_rule {
    name                       = "AllowAllOutbound"
    priority                   = 1000
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
    description                = "Allow all outbound traffic"
  }
}

# Master Subnet
resource "azurerm_subnet" "master" {
  name                 = var.master_subnet_name
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = var.master_subnet_address_prefixes
}


# Worker Subnet
resource "azurerm_subnet" "worker" {
  name                 = var.worker_subnet_name
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = var.worker_subnet_address_prefixes
}

