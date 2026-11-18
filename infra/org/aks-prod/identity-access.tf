# Kubelet-identity access to the registry and the Key Vault: image pull and Key
# Vault CSI for every namespace with no hand-seeded in-cluster secrets. Same
# pattern as product-a, minus the aliased provider: here registry and vault sit in
# the cluster's own subscription.
#
# Workloads that need anything more sensitive get their own federated identity
# instead (../backup, ../identities/trivy), because anything the kubelet can do,
# every pod on the node can do through IMDS.

data "azurerm_container_registry" "org" {
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name
}

data "azurerm_key_vault" "app" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = data.azurerm_container_registry.org.id

  skip_service_principal_aad_check = true
}

# getSecret + readMetadata and nothing more: what the CSI driver needs for
# objectType: secret. `az keyvault set-policy` is NOT an alternative on an
# RBAC-mode vault: ARM accepts the write and the data plane ignores it.
resource "azurerm_role_assignment" "aks_kv_secrets" {
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "Key Vault Secrets User"
  scope                = data.azurerm_key_vault.app.id

  skip_service_principal_aad_check = true
}
