output "vnet_id" {
  description = "ID of the virtual network."
  value       = azurerm_virtual_network.this.id
}

output "frontend_subnet_id" {
  description = "ID of the frontend subnet (ingress controller)."
  value       = azurerm_subnet.frontend.id
}

output "backend_subnet_id" {
  description = "ID of the backend subnet (AKS node pool)."
  value       = azurerm_subnet.backend.id
}

output "data_subnet_id" {
  description = "ID of the data subnet (delegated to PostgreSQL Flexible Server)."
  value       = azurerm_subnet.data.id
}
