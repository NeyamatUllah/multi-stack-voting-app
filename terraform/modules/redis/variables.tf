variable "resource_group_name" {
  type        = string
  description = "Name of the parent resource group."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "sku_name" {
  type        = string
  description = "Redis SKU (Basic, Standard, Premium)."
}

variable "capacity" {
  type        = number
  description = "Cache size — 0 to 6 for Basic/Standard, 1 to 4 for Premium."
}

variable "family" {
  type        = string
  description = "Cache family — C for Basic/Standard, P for Premium."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources."
  default     = {}
}
