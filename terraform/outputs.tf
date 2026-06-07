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

output "redis_host" {
  description = "Hostname of the Azure Cache for Redis instance."
  value       = module.redis.hostname
}

output "redis_ssl_port" {
  description = "SSL port for Redis — prefer this over non-SSL in production."
  value       = module.redis.ssl_port
}

output "redis_non_ssl_port" {
  description = "Non-SSL port (6379) — enabled for app compatibility; migrate to SSL port in production."
  value       = 6379
}

output "redis_primary_key" {
  description = "Primary access key for the Redis instance."
  value       = module.redis.primary_access_key
  sensitive   = true
}
