# tfsec:ignore:AVD-AZU-0028 — non-SSL port enabled for app compatibility.
# The vote and worker services use the Redis client without SSL configuration.
# Production hardening: set non_ssl_port_enabled = false and update apps to
# connect on port 6380 with SSL.
resource "azurerm_redis_cache" "this" {
  name                 = "voting-app-redis"
  resource_group_name  = var.resource_group_name
  location             = var.location
  capacity             = var.capacity
  family               = var.family
  sku_name             = var.sku_name
  non_ssl_port_enabled = true
  minimum_tls_version  = "1.2"
  tags                 = var.tags

  redis_configuration {}
}
# Note: Basic/Standard tiers do not support private endpoints or VNet injection.
# Upgrade to Premium tier and configure subnet_id to restrict network access.
