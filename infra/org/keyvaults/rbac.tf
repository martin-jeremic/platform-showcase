# Who may read and write the vaults' secrets. Same shape as ../registry/rbac.tf.
#
# Grants owned by other stacks are NOT here: the cluster kubelet identities'
# Secrets User grants (the cluster stacks), the Backstage identity's
# (../identities/backstage). The consumer side owns the grant; the inventory
# that told them apart from hand-made grants is the import plan.

locals {
  # "<principal>|<role>|<vault, or the resource group's name>" -- the address reads
  # as what it grants, and a duplicate entry is a plan-time error.
  role_assignments = {
    for g in var.role_assignments :
    "${coalesce(g.user, g.client_id)}|${g.role}|${coalesce(g.vault, var.resource_group_name)}" => g
  }

  principal_ids = merge(
    { for upn, user in data.azuread_user.grantee : upn => user.object_id },
    { for app_id, sp in data.azuread_service_principal.grantee : app_id => sp.object_id },
  )
}

data "azuread_user" "grantee" {
  for_each = toset([for g in var.role_assignments : g.user if g.user != null])

  user_principal_name = each.value
}

data "azuread_service_principal" "grantee" {
  for_each = toset([for g in var.role_assignments : g.client_id if g.client_id != null])

  client_id = each.value
}

# The scope is always the DERIVED id, never a copied string. Two resource-group
# grants are stored in Azure with `resourcegroups` in lower case; a verbatim copy of
# that string planned both as a REPLACE, because after import the provider holds the
# scope in its canonical `resourceGroups` form. The derived id matches.
resource "azurerm_role_assignment" "grant" {
  for_each = local.role_assignments

  scope                = each.value.vault == null ? azurerm_resource_group.rg.id : azurerm_key_vault.kv[each.value.vault].id
  role_definition_name = each.value.role
  principal_id         = local.principal_ids[coalesce(each.value.user, each.value.client_id)]
  principal_type       = each.value.user != null ? "User" : "ServicePrincipal"
}
