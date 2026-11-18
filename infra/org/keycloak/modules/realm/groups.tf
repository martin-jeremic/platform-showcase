# Groups and their role mappings. Membership is deliberately unmanaged (users are
# runtime data). Deleting a group here silently revokes access for everyone in it,
# which is why a plan on this stack is read before it is applied.
resource "keycloak_group" "this" {
  for_each = var.groups

  realm_id    = keycloak_realm.this.id
  name        = each.key
  description = each.value.description
  attributes  = each.value.attributes
}

# keycloak_group_roles is AUTHORITATIVE (exhaustive = true), so it is declared only
# for groups that declare at least one role. A group with none gets no resource, so
# a role granted in the console later is not silently stripped by an unrelated
# apply.
locals {
  groups_with_roles = { for k, g in var.groups : k => g if length(g.realm_roles) > 0 || length(g.client_roles) > 0 }

  group_unmanaged_realm_roles = toset(flatten([
    for k, g in local.groups_with_roles : [for r in g.realm_roles : r if !contains(keys(var.roles), r)]
  ]))

  # "<clientId>/<role>" for every client role any group maps.
  group_client_role_refs = toset(flatten([
    for k, g in local.groups_with_roles : flatten([
      for client, roles in g.client_roles : [for r in roles : "${client}/${r}"]
    ])
  ]))
}

# realm_id is the realm NAME, not keycloak_realm.this.id: a reference to the realm
# resource defers these reads to APPLY whenever the realm has pending changes, and
# the unknown role ids then replan every group's role set. See clients.tf.
data "keycloak_role" "group_realm" {
  for_each = local.group_unmanaged_realm_roles

  realm_id = var.realm
  name     = each.value
}

data "keycloak_role" "group_client" {
  for_each = local.group_client_role_refs

  realm_id  = var.realm
  client_id = local.role_container_ids[split("/", each.value)[0]]
  name      = split("/", each.value)[1]
}

resource "keycloak_group_roles" "this" {
  for_each = local.groups_with_roles

  realm_id   = keycloak_realm.this.id
  group_id   = keycloak_group.this[each.key].id
  exhaustive = true

  role_ids = concat(
    [for r in each.value.realm_roles : contains(keys(var.roles), r) ? local.realm_role_ids[r] : data.keycloak_role.group_realm[r].id],
    flatten([
      for client, roles in each.value.client_roles : [
        for r in roles :
        contains(keys(local.client_role_ids), "${client}/${r}") ? local.client_role_ids["${client}/${r}"] : data.keycloak_role.group_client["${client}/${r}"].id
      ]
    ]),
  )
}
