# Private DNS zone required for PostgreSQL Flexible Server VNet integration.
# The server registers its FQDN (<server-name>.<zone>) so pods resolve to the
# private IP without traversing the public internet.
resource "azurerm_private_dns_zone" "this" {
  name                = "voting-app.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  name                  = "postgres-vnet-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this.name
  virtual_network_id    = var.vnet_id
  tags                  = var.tags
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                   = "voting-app-postgres"
  resource_group_name    = var.resource_group_name
  location               = var.location
  version                = var.server_version
  delegated_subnet_id    = var.data_subnet_id
  private_dns_zone_id    = azurerm_private_dns_zone.this.id
  administrator_login    = var.admin_username
  administrator_password = var.admin_password
  zone                   = "1"
  sku_name               = var.sku_name
  storage_mb             = 32768
  backup_retention_days  = 7

  geo_redundant_backup_enabled  = false
  public_network_access_enabled = false

  tags = var.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.this]
}

resource "azurerm_postgresql_flexible_server_database" "votes" {
  name      = "postgres"
  server_id = azurerm_postgresql_flexible_server.this.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}
