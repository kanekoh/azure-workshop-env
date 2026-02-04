variable "resource_group_name" {
  description = "Name of the Azure Resource Group (from network phase)"
  type        = string
}

variable "location" {
  description = "Azure region for resources (from network phase)"
  type        = string
}

variable "vnet_id" {
  description = "ID of the Virtual Network (from network phase)"
  type        = string
}

variable "master_subnet_id" {
  description = "ID of the master subnet (from network phase)"
  type        = string
}

variable "worker_subnet_id" {
  description = "ID of the worker subnet (from network phase)"
  type        = string
}

variable "cluster_name" {
  description = "Name of the ARO cluster"
  type        = string
}

variable "domain" {
  description = "Domain name for the cluster"
  type        = string
  default     = ""
}

variable "ocp_version" {
  description = "OpenShift Container Platform version"
  type        = string
  default     = "4.14"
}

variable "master_vm_size" {
  description = "VM size for master nodes"
  type        = string
  default     = "Standard_D8s_v3"
}

variable "master_disk_size" {
  description = "Disk size (GB) for master nodes"
  type        = number
  default     = 128
}

variable "worker_vm_size" {
  description = "VM size for worker nodes"
  type        = string
  default     = "Standard_D4s_v3"
}

variable "worker_disk_size" {
  description = "Disk size (GB) for worker nodes"
  type        = number
  default     = 128
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "pod_cidr" {
  description = "CIDR for pods"
  type        = string
  default     = "10.128.0.0/14"
}

variable "service_cidr" {
  description = "CIDR for services"
  type        = string
  default     = "172.30.0.0/16"
}

variable "pull_secret" {
  description = "Red Hat pull secret (optional, can be set via environment variable)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
