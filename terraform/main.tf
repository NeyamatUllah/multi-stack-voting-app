resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

module "networking" {
  source = "./modules/networking"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags
}

module "aks" {
  source = "./modules/aks"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  kubernetes_version  = var.kubernetes_version
  node_count          = var.aks_node_count
  node_vm_size        = var.aks_node_vm_size
  backend_subnet_id   = module.networking.backend_subnet_id
  tags                = var.tags
}

module "postgres" {
  source = "./modules/postgres"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  vnet_id             = module.networking.vnet_id
  data_subnet_id      = module.networking.data_subnet_id
  admin_username      = var.postgres_admin_username
  admin_password      = var.postgres_admin_password
  sku_name            = var.postgres_sku_name
  server_version      = var.postgres_version
  tags                = var.tags
}

module "redis" {
  source = "./modules/redis"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku_name            = var.redis_sku_name
  capacity            = var.redis_capacity
  family              = var.redis_family
  tags                = var.tags
}
