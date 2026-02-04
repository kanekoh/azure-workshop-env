output "cluster_id" {
  description = "ID of the ARO cluster"
  value       = azurerm_redhat_openshift_cluster.aro.id
}

output "cluster_name" {
  description = "Name of the ARO cluster"
  value       = azurerm_redhat_openshift_cluster.aro.name
}

output "cluster_fqdn" {
  description = "FQDN of the ARO cluster"
  value       = azurerm_redhat_openshift_cluster.aro.fqdn
}

output "api_server_url" {
  description = "API server URL of the ARO cluster (use 'az aro show' to get actual URL)"
  value       = try(azurerm_redhat_openshift_cluster.aro.apiserver_profile[0].url, "https://api.${azurerm_redhat_openshift_cluster.aro.fqdn}:6443")
}

output "console_url" {
  description = "Console URL of the ARO cluster (use 'az aro show' to get actual URL)"
  value       = try(azurerm_redhat_openshift_cluster.aro.console_profile[0].url, "https://console-openshift-console.apps.${azurerm_redhat_openshift_cluster.aro.fqdn}")
}

output "resource_group_name" {
  description = "Name of the resource group"
  value       = var.resource_group_name
}

output "location" {
  description = "Location of the cluster"
  value       = var.location
}
