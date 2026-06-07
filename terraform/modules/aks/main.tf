resource "azurerm_log_analytics_workspace" "this" {
  name                = "voting-app-logs"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# tfsec:ignore:AVD-AZU-0040 — private cluster adds significant complexity for a learning deployment
resource "azurerm_kubernetes_cluster" "this" {
  name                = "voting-app-aks"
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_prefix          = "voting-app"
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  default_node_pool {
    name            = "system"
    node_count      = var.node_count
    vm_size         = var.node_vm_size
    vnet_subnet_id  = var.backend_subnet_id
    os_disk_size_gb = 50
  }

  identity {
    type = "SystemAssigned"
  }

  # Azure CNI keeps pod IPs in the VNet subnet; required for Calico NetworkPolicy
  # enforcement — consistent with the Phase 5 Minikube setup.
  network_profile {
    network_plugin    = "azure"
    network_policy    = "calico"
    load_balancer_sku = "standard"
    service_cidr      = "10.1.0.0/16"
    dns_service_ip    = "10.1.0.10"
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }
}
