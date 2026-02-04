output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "resource_group_location" {
  description = "Location of the resource group"
  value       = azurerm_resource_group.main.location
}

output "vnet_id" {
  description = "ID of the Virtual Network"
  value       = azurerm_virtual_network.main.id
}

output "vnet_name" {
  description = "Name of the Virtual Network"
  value       = azurerm_virtual_network.main.name
}

output "master_subnet_id" {
  description = "ID of the master subnet"
  value       = azurerm_subnet.master.id
}

output "master_subnet_name" {
  description = "Name of the master subnet"
  value       = azurerm_subnet.master.name
}

output "worker_subnet_id" {
  description = "ID of the worker subnet"
  value       = azurerm_subnet.worker.id
}

output "worker_subnet_name" {
  description = "Name of the worker subnet"
  value       = azurerm_subnet.worker.name
}

output "network_security_group_id" {
  description = "ID of the Network Security Group"
  value       = azurerm_network_security_group.aro.id
}
