# Kubelet-identity access to the shared registries and the per-environment vault.
# Same shape as ../aks-demo/identity-access.tf; this is an IDENTITY grant, not a
# network one: the cluster pulls from the registry's public endpoint with Entra
# auth, so no peering between the two subscriptions is needed.

data "azurerm_container_registry" "app" {
  provider            = azurerm.shared
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name
}

# Gated. A data source on a vault that does not exist yet is a hard `tofu plan`
# failure, not a warning. Flip enable_key_vault_access once the vault exists.
data "azurerm_key_vault" "app" {
  count = var.enable_key_vault_access ? 1 : 0

  provider            = azurerm.shared
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  provider             = azurerm.shared
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = data.azurerm_container_registry.app.id

  skip_service_principal_aad_check = true
}

# A second registry holds the identity-provider image built by the platform team.
# AcrPull is scoped PER REGISTRY, so the grant above does not cover it; without
# this the pods sit in ImagePullBackOff with a 401 that looks like a bad digest.
#
# Kept as a SEPARATE resource rather than folding the first registry into a
# for_each: that would change the existing assignment's address and force a
# destroy/create -- a window in which no node can pull anything.
data "azurerm_container_registry" "additional" {
  for_each = var.additional_acr_names

  provider            = azurerm.shared
  name                = each.value
  resource_group_name = var.acr_resource_group_name
}

resource "azurerm_role_assignment" "aks_acr_pull_additional" {
  for_each = var.additional_acr_names

  provider             = azurerm.shared
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = data.azurerm_container_registry.additional[each.value].id

  skip_service_principal_aad_check = true
}

# KNOWN GAP (README): the kubelet identity holding Key Vault Secrets User gives
# every pod on the node read access to the vault through IMDS. The per-workload
# replacement is the four-object pattern in identity-workload.tf.
resource "azurerm_role_assignment" "aks_kv_secrets" {
  count = var.enable_key_vault_access ? 1 : 0

  provider             = azurerm.shared
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name = "Key Vault Secrets User"
  scope                = data.azurerm_key_vault.app[0].id

  skip_service_principal_aad_check = true
}
