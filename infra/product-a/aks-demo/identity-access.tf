# Kubelet-identity access to the shared registry and the per-environment Key Vault.
#
# Grants the cluster's KUBELET managed identity (not the control-plane identity)
# two roles, so every namespace gets image pull and Key Vault CSI access with no
# hand-seeded in-cluster secrets:
#   - AcrPull on the shared registry
#   - Key Vault Secrets User on the per-env vault (RBAC authorization mode)
#
# Both live in the shared-services subscription, so the data sources and the
# assignments go through the azurerm.shared alias. IDs are resolved through data
# sources, never hard-coded.
#
# KNOWN GAP: anything the kubelet identity can do, every pod on the node can do
# through IMDS. AcrPull cluster-wide is harmless; Key Vault Secrets User
# cluster-wide is not. The per-workload alternative is shown in trivy-identity.tf
# and in ../aks-prod/identity-workload.tf. See the README KNOWN-GAPS.

data "azurerm_container_registry" "shared" {
  provider            = azurerm.shared
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name
}

data "azurerm_key_vault" "app" {
  provider            = azurerm.shared
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  provider             = azurerm.shared
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = data.azurerm_container_registry.shared.id

  # The kubelet identity may not have propagated to Entra yet on the first apply.
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "aks_kv_secrets" {
  provider             = azurerm.shared
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "Key Vault Secrets User"
  scope                = data.azurerm_key_vault.app.id

  skip_service_principal_aad_check = true
}
