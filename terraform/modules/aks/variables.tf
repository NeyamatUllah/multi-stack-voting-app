variable "resource_group_name" {
  type        = string
  description = "Name of the parent resource group."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for the AKS cluster."
}

variable "node_count" {
  type        = number
  description = "Number of nodes in the default node pool."
}

variable "node_vm_size" {
  type        = string
  description = "VM SKU for AKS nodes."
}

variable "backend_subnet_id" {
  type        = string
  description = "ID of the backend subnet to place AKS nodes in."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources."
  default     = {}
}
