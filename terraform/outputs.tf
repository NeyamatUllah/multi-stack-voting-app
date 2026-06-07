output "resource_group_name" {
  description = "Name of the Azure resource group."
  value       = azurerm_resource_group.this.name
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster."
  value       = module.aks.cluster_name
}

output "kube_config" {
  description = "Raw kubeconfig. Use: terraform output -raw kube_config > ~/.kube/config"
  value       = module.aks.kube_config_raw
  sensitive   = true
}

output "postgres_host" {
  description = "FQDN of the PostgreSQL Flexible Server."
  value       = module.postgres.fqdn
}

output "postgres_port" {
  description = "PostgreSQL port (always 5432)."
  value       = 5432
}

output "postgres_admin_username" {
  description = "PostgreSQL administrator login."
  value       = module.postgres.admin_username
}

# Redis outputs removed — Azure Cache for Redis retired in this region.
# In-cluster Redis K8s Deployment is used; no external Redis credentials needed.
