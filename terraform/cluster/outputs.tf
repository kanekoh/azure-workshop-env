output "cluster_id" {
  description = "ID of the ARO cluster"
  value       = azurerm_redhat_openshift_cluster.aro.id
}

output "cluster_name" {
  description = "Name of the ARO cluster"
  value       = azurerm_redhat_openshift_cluster.aro.name
}

output "api_server_url" {
  description = "API server URL of the ARO cluster"
  value       = azurerm_redhat_openshift_cluster.aro.api_server_profile[0].url
}

output "console_url" {
  description = "Console URL of the ARO cluster"
  value       = azurerm_redhat_openshift_cluster.aro.console_url
}

output "resource_group_name" {
  description = "Name of the resource group"
  value       = var.resource_group_name
}

output "location" {
  description = "Location of the cluster"
  value       = var.location
}
