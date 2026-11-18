# The user-added client scopes and their mappers. Everything else in
# /client-scopes is a Keycloak built-in and stays unmanaged -- established by
# diffing this realm's scope list against an untouched master realm, which is also
# how `service_account` turned out to be a built-in despite looking custom.

# One definition, three scopes: genuinely uniform, only name and description differ.
resource "keycloak_openid_client_scope" "audit" {
  for_each = local.audit_scopes

  realm_id               = local.realm_id
  name                   = each.key
  description            = each.value
  include_in_token_scope = true
}

# Each audit scope carries an audience mapper naming the audit resource client, so
# a token minted with the scope also carries the `aud` the audit service validates.
resource "keycloak_openid_audience_protocol_mapper" "audit" {
  for_each = local.audit_scopes

  realm_id        = local.realm_id
  client_scope_id = keycloak_openid_client_scope.audit[each.key].id
  name            = local.audit_audience_mapper_name

  included_client_audience   = keycloak_openid_client.audit.client_id
  add_to_access_token        = true
  add_to_id_token            = false
  add_to_token_introspection = true
}

# Flattens group membership into a `groups` claim. Realm-wide on purpose: the
# root-level platform clients (Argo CD, Grafana) take it as a DEFAULT scope.
resource "keycloak_openid_client_scope" "groups" {
  realm_id               = local.realm_id
  name                   = "groups"
  include_in_token_scope = true
}

resource "keycloak_openid_group_membership_protocol_mapper" "groups" {
  realm_id        = local.realm_id
  client_scope_id = keycloak_openid_client_scope.groups.id
  name            = "groups"

  claim_name = "groups"
  full_path  = false

  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true

  # Load-bearing on this mapper. Keycloak reports introspection.token.claim = true
  # (it fills the value from access.token.claim when the stored config lacks it),
  # but the provider's default for group-membership mappers is FALSE. Left at the
  # default, the plan carries a true -> false update that drops `groups` from token
  # introspection.
  add_to_token_introspection = true
}

# included_custom_audience, NOT included_client_audience: the live mapper stores
# the audience as a literal string rather than a client reference. Swapping the two
# arguments produces a permanent diff.
resource "keycloak_openid_client_scope" "mcp_data_read" {
  realm_id               = local.realm_id
  name                   = "mcp-data:read"
  include_in_token_scope = true
}

resource "keycloak_openid_audience_protocol_mapper" "mcp_data" {
  realm_id        = local.realm_id
  client_scope_id = keycloak_openid_client_scope.mcp_data_read.id
  name            = "mcp-data-audience"

  included_custom_audience   = "product-a-mcp-data"
  add_to_access_token        = true
  add_to_id_token            = false
  add_to_token_introspection = true
}

resource "keycloak_openid_client_scope" "marker" {
  for_each = toset(local.marker_scopes)

  realm_id               = local.realm_id
  name                   = each.value
  include_in_token_scope = false
}
