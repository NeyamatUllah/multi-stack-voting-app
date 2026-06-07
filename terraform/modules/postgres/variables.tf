variable "resource_group_name" {
  type        = string
  description = "Name of the parent resource group."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "vnet_id" {
  type        = string
  description = "ID of the VNet to link the private DNS zone to."
}

variable "data_subnet_id" {
  type        = string
  description = "ID of the delegated data subnet for the PostgreSQL Flexible Server."
}

variable "admin_username" {
  type        = string
  description = "Administrator login name."
}

variable "admin_password" {
  type        = string
  description = "Administrator password."
  sensitive   = true
}

variable "sku_name" {
  type        = string
  description = "PostgreSQL Flexible Server SKU (e.g. B_Standard_B1ms)."
}

variable "server_version" {
  type        = string
  description = "PostgreSQL engine version."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources."
  default     = {}
}
