variable "resource_group_name" {
  type        = string
  description = "Name of the Azure resource group."
  default     = "voting-app-rg"
}

variable "location" {
  type        = string
  description = "Azure region to deploy all resources."
  default     = "uksouth"
}

variable "environment" {
  type        = string
  description = "Deployment environment tag (e.g. prod, staging)."
  default     = "prod"
}

variable "aks_node_count" {
  type        = number
  description = "Number of nodes in the default AKS node pool."
  default     = 1
}

variable "aks_node_vm_size" {
  type        = string
  description = "VM SKU for AKS nodes."
  default     = "Standard_B2ms"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for the AKS cluster."
  default     = "1.34"
}

variable "postgres_admin_username" {
  type        = string
  description = "Administrator login name for the PostgreSQL Flexible Server."
  default     = "psqladmin"
}

variable "postgres_admin_password" {
  type        = string
  description = "Administrator password for the PostgreSQL Flexible Server."
  sensitive   = true
}

variable "postgres_sku_name" {
  type        = string
  description = "SKU for the PostgreSQL Flexible Server (e.g. B_Standard_B1ms)."
  default     = "B_Standard_B1ms"
}

variable "postgres_version" {
  type        = string
  description = "PostgreSQL engine version."
  default     = "15"
}

variable "redis_sku_name" {
  type        = string
  description = "SKU for Azure Cache for Redis (Basic, Standard, Premium)."
  default     = "Basic"
}

variable "redis_capacity" {
  type        = number
  description = "Cache size — 0 to 6 for Basic/Standard, 1 to 4 for Premium."
  default     = 0
}

variable "redis_family" {
  type        = string
  description = "Cache family — C for Basic/Standard, P for Premium."
  default     = "C"
}

variable "dns_zone_name" {
  type        = string
  description = "Azure DNS zone for ExternalDNS (e.g. example.com). Zone must already exist in Azure."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to all resources."
  default = {
    project    = "voting-app"
    managed_by = "terraform"
  }
}
