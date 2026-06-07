output "fqdn" {
  description = "FQDN of the PostgreSQL Flexible Server."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "server_name" {
  description = "Name of the PostgreSQL Flexible Server resource."
  value       = azurerm_postgresql_flexible_server.this.name
}

output "admin_username" {
  description = "Administrator login name."
  value       = azurerm_postgresql_flexible_server.this.administrator_login
}
