output "hostname" {
  description = "Hostname of the Azure Cache for Redis instance."
  value       = azurerm_redis_cache.this.hostname
}

output "ssl_port" {
  description = "SSL port (6380) — preferred for production connections."
  value       = azurerm_redis_cache.this.ssl_port
}

output "primary_access_key" {
  description = "Primary access key for the Redis instance."
  value       = azurerm_redis_cache.this.primary_access_key
  sensitive   = true
}
