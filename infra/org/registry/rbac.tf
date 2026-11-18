# Who may push to and pull from the registries. The grants are DATA in
# var.role_assignments; this file turns each entry into one role assignment.
#
# The cluster kubelet identities' AcrPull grants are NOT here: the cluster stacks
# create those identities and own their grants (the consumer side). The same goes
# for the Trivy identities. They were told apart from hand-made grants during the
# inventory (rule 3 of ../../docs/import-methodology.md).

locals {
  # A grant's state address is derived from the grant itself,
  # "<principal>|<role>|<registry>", so the address reads as what it grants and a
  # duplicate entry is a plan-time error rather than two assignments.
  role_assignments = {
    for g in var.role_assignments :
    "${coalesce(g.user, g.client_id)}|${g.role}|${g.registry}" => g
  }

  principal_ids = merge(
    { for upn, user in data.azuread_user.grantee : upn => user.object_id },
    { for app_id, sp in data.azuread_service_principal.grantee : app_id => sp.object_id },
  )
}

# A principal is named the way people recognise it -- a UPN for a user, the appId
# for a service principal or managed identity -- and resolved to an object id at
# plan time. A grantee deleted from Entra therefore FAILS THE PLAN instead of being
# carried forward as an orphaned assignment.
data "azuread_user" "grantee" {
  for_each = toset([for g in var.role_assignments : g.user if g.user != null])

  user_principal_name = each.value
}

data "azuread_service_principal" "grantee" {
  for_each = toset([for g in var.role_assignments : g.client_id if g.client_id != null])

  client_id = each.value
}

# principal_type is stated so a new grant does not race Entra replication while
# the provider looks the type up. For every imported grant it equals the live value.
resource "azurerm_role_assignment" "grant" {
  for_each = local.role_assignments

  scope                = azurerm_container_registry.acr[each.value.registry].id
  role_definition_name = each.value.role
  principal_id         = local.principal_ids[coalesce(each.value.user, each.value.client_id)]
  principal_type       = each.value.user != null ? "User" : "ServicePrincipal"
}
