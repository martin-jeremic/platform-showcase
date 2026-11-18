# Custom realm roles. Built-ins (offline_access, uma_authorization,
# default-roles-<realm>) are never declared.
#
# TWO resources rather than one, so a composite can reference the flat roles by
# name: a resource cannot reference its own instances.
locals {
  flat_realm_roles      = { for k, r in var.roles : k => r if length(coalesce(r.composite_roles, [])) == 0 }
  composite_realm_roles = { for k, r in var.roles : k => r if length(coalesce(r.composite_roles, [])) > 0 }
}

resource "keycloak_role" "realm" {
  for_each = local.flat_realm_roles

  realm_id    = keycloak_realm.this.id
  name        = each.key
  description = each.value.description
  attributes  = each.value.attributes

  # Flat means flat. composite_roles is Optional+Computed: left null it plans as
  # "(known after apply)" on every imported role, and it never notices a composite
  # added in the console, so a "flat" role here would enforce nothing. An explicit
  # empty set states the fact and holds it. Roles whose live composites this module
  # cannot express are REFUSED by the exporter rather than silently flattened.
  composite_roles = []
}

resource "keycloak_role" "realm_composite" {
  for_each = local.composite_realm_roles

  realm_id        = keycloak_realm.this.id
  name            = each.key
  description     = each.value.description
  attributes      = each.value.attributes
  composite_roles = [for c in each.value.composite_roles : keycloak_role.realm[c].id]
}

locals {
  realm_role_ids = merge(
    { for k, r in keycloak_role.realm : k => r.id },
    { for k, r in keycloak_role.realm_composite : k => r.id },
  )
}
