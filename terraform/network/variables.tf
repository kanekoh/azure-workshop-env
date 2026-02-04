variable "resource_group_name" {
  description = "Name of the Azure Resource Group"
  type        = string
}

variable "location" {
  description = "Azure region for resources"
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

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
