# The portal mounts its backstage--* secrets with this identity (SecretProviderClass
# in workload-identity mode), so no static credentials Secret exists in its
# namespace.
#
# The grant lives HERE, with the consumer, the way the cluster stacks own their
# kubelet grants; ../../keyvaults lists it among grants other states own. Vault
# scope: the role reads nothing but secrets, and per-secret scope would need every
# object to exist before this apply.
data "azurerm_key_vault" "vault" {
  for_each = toset(var.key_vaults)

  name                = each.key
  resource_group_name = var.key_vault_resource_group_name
}

resource "azurerm_role_assignment" "key_vault_secrets_user" {
  for_each = data.azurerm_key_vault.vault

  scope                = each.value.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.backstage.principal_id
  principal_type       = "ServicePrincipal"
}

# auth.session.secret: signs the auth backend's session cookie, which carries the
# OIDC state/nonce across the redirect to Keycloak. Generated here and written
# straight into each vault the pod mounts from, so nobody types or sees it.
# Rotating (`tofu apply -replace='random_password.session["kv-org-dev"]'`) only
# invalidates sign-ins in flight at that moment.
resource "random_password" "session" {
  for_each = data.azurerm_key_vault.vault

  length  = 48
  special = false
}

resource "azurerm_key_vault_secret" "session" {
  for_each = data.azurerm_key_vault.vault

  name         = "backstage--auth-session-secret"
  value        = random_password.session[each.key].result
  key_vault_id = each.value.id
  content_type = "Backstage auth.session.secret (org/identities/backstage)"
  tags         = var.tags
}
