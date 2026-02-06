variable "resource_group_name" {
  description = "Name of the Azure Resource Group"
  type        = string
}

variable "resource_group_create" {
  description = "Whether to create the resource group (false if it already exists)"
  type        = bool
  default     = true
}

variable "location" {
  description = "Azure region for resources (ignored if resource group already exists)"
  type        = string
  default     = "japaneast"
}

variable "vnet_name" {
  description = "Name of the Virtual Network"
  type        = string
  default     = "aro-vnet"
}

variable "vnet_address_space" {
  description = "Address space for the Virtual Network"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "master_subnet_name" {
  description = "Name of the master subnet"
  type        = string
  default     = "aro-master-subnet"
}

variable "master_subnet_address_prefixes" {
  description = "Address prefixes for the master subnet"
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "worker_subnet_name" {
  description = "Name of the worker subnet"
  type        = string
  default     = "aro-worker-subnet"
}

variable "worker_subnet_address_prefixes" {
  description = "Address prefixes for the worker subnet"
  type        = list(string)
  default     = ["10.0.2.0/24"]
}

variable "aro_rp_service_principal_object_id" {
  description = "Object ID for ARO resource provider service principal (optional, will be looked up if not provided)"
  type        = string
  default     = ""
}

variable "aro_rp_service_principal_client_id" {
  description = "Client ID (application ID) for ARO resource provider service principal"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
