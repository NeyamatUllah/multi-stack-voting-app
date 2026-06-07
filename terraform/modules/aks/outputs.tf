output "cluster_name" {
  description = "Name of the AKS cluster."
  value       = azurerm_kubernetes_cluster.this.name
}

output "kube_config_raw" {
  description = "Raw kubeconfig. Use: terraform output -raw kube_config > ~/.kube/config"
  value       = azurerm_kubernetes_cluster.this.kube_config_raw
  sensitive   = true
}
