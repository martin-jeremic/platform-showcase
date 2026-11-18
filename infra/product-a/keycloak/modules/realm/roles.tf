# Realm roles we own. Uniform shape, so for_each rather than near-identical blocks.
# Keycloak's own roles stay unmanaged: Keycloak creates and upgrades them, and
# managing them means fighting the product on every version bump.

resource "keycloak_role" "realm" {
  for_each = local.realm_roles

  realm_id    = local.realm_id
  name        = each.key
  description = each.value

  # None of these is composite, and that is DECLARED rather than left out. The
  # provider writes composite_roles to state only when a role IS composite, and the
  # attribute is Optional+Computed, so an undeclared one plans as
  # "(known after apply)" on every run -- a permanent no-op update that keeps
  # `tofu plan` from ever printing "No changes". `[]` also makes a composite added
  # by hand show up as drift.
  composite_roles = []
}

# Membership-only groups. A single for_each covers them all because none has
# subgroups, attributes or role mappings.
resource "keycloak_group" "this" {
  for_each = toset(local.tenant_groups)

  realm_id = local.realm_id
  name     = each.value
}
