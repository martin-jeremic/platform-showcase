# ---------------------------------------------------------------------------
# OpenID Connect clients
# ---------------------------------------------------------------------------

# PROVIDER GUARD. getOpenidClientFromData refuses `valid_redirect_uris` unless
# the standard or implicit flow is on, and refuses `web_origins` unless one of
# standard / implicit / direct-access-grant is on. The guard runs on create and
# update, never on plan, so a violating config plans clean and fails at apply.
#
# Without the matching flow both fields are inert in Keycloak, but console-made
# service-account clients often carry a live `["/*"]` (or `[""]`) in them. Such a
# client can never be written by the provider as it is: the guard reads the
# values from state, so leaving the argument null still fails on the first
# update (four clients failed the first adoption apply that way). The
# module therefore declares both fields EMPTY when the flow that uses them is off.
# The first update clears the inert live values, and the declaration then holds.
locals {
  client_has_browser_flow = {
    for k, c in var.clients : k => c.standard_flow_enabled || c.implicit_flow_enabled
  }
  client_can_have_web_origins = {
    for k, c in var.clients : k => local.client_has_browser_flow[k] || c.direct_access_grants_enabled
  }

  # Flow aliases used in per-client binding overrides that this module does not
  # declare itself (built-ins, or flows owned elsewhere) are looked up by alias.
  override_flow_aliases = toset(compact(flatten([
    for k, c in var.clients :
    c.authentication_flow_binding_overrides == null ? [] : [
      c.authentication_flow_binding_overrides.browser,
      c.authentication_flow_binding_overrides.direct_grant,
    ]
  ])))
  unmanaged_override_flow_aliases = toset([
    for a in local.override_flow_aliases : a if !contains(keys(var.authentication_flows), a)
  ])
}

# realm_id is the realm NAME, never keycloak_realm.this.id. A data source that
# references a managed resource with pending changes is read during apply
# instead of during plan, so every attribute it returns is unknown in the plan.
# Downstream that turns into `forces replacement` on resources whose argument is
# ForceNew (see role_container below). The objects looked up here already exist
# whenever the realm does, so nothing is lost by reading them at plan time.
data "keycloak_authentication_flow" "override" {
  for_each = local.unmanaged_override_flow_aliases

  realm_id = var.realm
  alias    = each.value
}

locals {
  override_flow_ids = merge(
    { for k, f in keycloak_authentication_flow.this : k => f.id },
    { for k, f in data.keycloak_authentication_flow.override : k => f.id },
  )
}

# `client_secret` is never set. It is Optional+Computed, so on import the live
# secret is read into state and, with nothing to compare against, never rotated.
# On a fresh create Keycloak mints one. Read it from the admin console or
# GET /clients/{id}/client-secret and put it straight into Key Vault.
resource "keycloak_openid_client" "this" {
  for_each = var.clients

  realm_id  = keycloak_realm.this.id
  client_id = each.key

  name                      = each.value.name
  description               = each.value.description
  enabled                   = each.value.enabled
  access_type               = each.value.access_type
  client_authenticator_type = each.value.client_authenticator_type

  standard_flow_enabled        = each.value.standard_flow_enabled
  implicit_flow_enabled        = each.value.implicit_flow_enabled
  direct_access_grants_enabled = each.value.direct_access_grants_enabled
  service_accounts_enabled     = each.value.service_accounts_enabled

  root_url  = each.value.root_url
  base_url  = each.value.base_url
  admin_url = each.value.admin_url

  valid_redirect_uris             = local.client_has_browser_flow[each.key] ? each.value.valid_redirect_uris : []
  valid_post_logout_redirect_uris = each.value.valid_post_logout_redirect_uris
  web_origins                     = local.client_can_have_web_origins[each.key] ? each.value.web_origins : []

  pkce_code_challenge_method = each.value.pkce_code_challenge_method
  full_scope_allowed         = each.value.full_scope_allowed
  consent_required           = each.value.consent_required
  display_on_consent_screen  = each.value.display_on_consent_screen
  consent_screen_text        = each.value.consent_screen_text
  login_theme                = each.value.login_theme
  always_display_in_console  = each.value.always_display_in_console

  frontchannel_logout_enabled                = each.value.frontchannel_logout_enabled
  frontchannel_logout_url                    = each.value.frontchannel_logout_url
  backchannel_logout_url                     = each.value.backchannel_logout_url
  backchannel_logout_session_required        = each.value.backchannel_logout_session_required
  backchannel_logout_revoke_offline_sessions = each.value.backchannel_logout_revoke_offline_sessions

  use_refresh_tokens                             = each.value.use_refresh_tokens
  use_refresh_tokens_client_credentials          = each.value.use_refresh_tokens_client_credentials
  standard_token_exchange_enabled                = each.value.standard_token_exchange_enabled
  allow_refresh_token_in_standard_token_exchange = each.value.allow_refresh_token_in_standard_token_exchange
  oauth2_device_authorization_grant_enabled      = each.value.oauth2_device_authorization_grant_enabled
  oauth2_device_code_lifespan                    = each.value.oauth2_device_code_lifespan
  oauth2_device_polling_interval                 = each.value.oauth2_device_polling_interval
  oauth2_jwt_authorization_grant_enabled         = each.value.oauth2_jwt_authorization_grant_enabled
  oauth2_jwt_authorization_grant_idp             = each.value.oauth2_jwt_authorization_grant_idp

  exclude_session_state_from_auth_response = each.value.exclude_session_state_from_auth_response
  exclude_issuer_from_auth_response        = each.value.exclude_issuer_from_auth_response
  require_dpop_bound_tokens                = each.value.require_dpop_bound_tokens

  access_token_lifespan               = each.value.access_token_lifespan
  client_session_idle_timeout         = each.value.client_session_idle_timeout
  client_session_max_lifespan         = each.value.client_session_max_lifespan
  client_offline_session_idle_timeout = each.value.client_offline_session_idle_timeout
  client_offline_session_max_lifespan = each.value.client_offline_session_max_lifespan

  extra_config = length(each.value.extra_config) > 0 ? each.value.extra_config : null

  # Presence of the block is what keeps authorization services enabled. Dropping
  # it would disable them, which also deletes the auto-created `uma_protection`
  # client role and the whole policy model.
  dynamic "authorization" {
    for_each = each.value.authorization == null ? [] : [each.value.authorization]
    content {
      policy_enforcement_mode          = authorization.value.policy_enforcement_mode
      decision_strategy                = authorization.value.decision_strategy
      allow_remote_resource_management = authorization.value.allow_remote_resource_management
      keep_defaults                    = authorization.value.keep_defaults
    }
  }

  dynamic "authentication_flow_binding_overrides" {
    for_each = each.value.authentication_flow_binding_overrides == null ? [] : [each.value.authentication_flow_binding_overrides]
    content {
      browser_id      = authentication_flow_binding_overrides.value.browser == null ? null : local.override_flow_ids[authentication_flow_binding_overrides.value.browser]
      direct_grant_id = authentication_flow_binding_overrides.value.direct_grant == null ? null : local.override_flow_ids[authentication_flow_binding_overrides.value.direct_grant]
    }
  }
}

# --- Scope attachments --------------------------------------------------------
#
# Both resources are AUTHORITATIVE: the listed set replaces whatever is attached,
# so a scope missing from a list is DETACHED on apply. The lists are therefore
# the full live lists, built-ins included. Neither resource is importable in
# provider 5.9, so on adoption they plan as creates; each create is a PUT of a
# list that already matches live, which is a server-side no-op. If one of those
# creates ever shows a list that differs from live, that is a real change
# wearing an import's clothes.
resource "keycloak_openid_client_default_scopes" "this" {
  for_each = var.clients

  realm_id       = keycloak_realm.this.id
  client_id      = keycloak_openid_client.this[each.key].id
  default_scopes = each.value.default_scopes

  depends_on = [keycloak_openid_client_scope.this]
}

resource "keycloak_openid_client_optional_scopes" "this" {
  for_each = var.clients

  realm_id        = keycloak_realm.this.id
  client_id       = keycloak_openid_client.this[each.key].id
  optional_scopes = each.value.optional_scopes

  depends_on = [keycloak_openid_client_scope.this]
}

# --- Protocol mappers ---------------------------------------------------------

locals {
  client_protocol_mappers = merge([
    for client, c in var.clients : {
      for name, m in c.protocol_mappers : "${client}/${name}" => merge(m, { client = client, name = name })
    }
  ]...)
}

# Generic mappers, config verbatim from GET /clients/{id}/protocol-mappers/models.
# See client-scopes.tf for why not the typed mapper resources.
resource "keycloak_generic_protocol_mapper" "client" {
  for_each = local.client_protocol_mappers

  realm_id  = keycloak_realm.this.id
  client_id = keycloak_openid_client.this[each.value.client].id

  name            = each.value.name
  protocol        = each.value.protocol
  protocol_mapper = each.value.protocol_mapper
  config          = each.value.config
}

# --- Client roles -------------------------------------------------------------

locals {
  client_roles = merge([
    for client, c in var.clients : {
      for name, r in c.roles : "${client}/${name}" => merge(r, { client = client, name = name })
    }
  ]...)
}

# The auto-generated `uma_protection` role of clients with authorization services
# is never declared here; Keycloak creates and deletes it with the toggle.
resource "keycloak_role" "client" {
  for_each = local.client_roles

  realm_id    = keycloak_realm.this.id
  client_id   = keycloak_openid_client.this[each.value.client].id
  name        = each.value.name
  description = each.value.description
  attributes  = each.value.attributes

  # Client roles are flat by definition here (see keycloak_role.realm in
  # roles.tf for why this is spelled out rather than left null).
  composite_roles = []
}

locals {
  client_role_ids = { for k, r in keycloak_role.client : k => r.id }
}

# --- Service-account role mappings -------------------------------------------

locals {
  sa_realm_roles = merge([
    for client, c in var.clients : {
      for r in c.service_account_realm_roles : "${client}/${r}" => { client = client, role = r }
    }
  ]...)

  sa_client_roles = merge(flatten([
    for client, c in var.clients : [
      for container, roles in c.service_account_client_roles : {
        for r in roles : "${client}/${container}/${r}" => { client = client, container = container, role = r }
      }
    ]
  ])...)

  # Clients whose roles are mapped somewhere (service accounts, groups) and that
  # this module does not itself declare, e.g. `realm-management`.
  referenced_role_containers = toset(concat(
    flatten([for k, c in var.clients : keys(c.service_account_client_roles)]),
    [for ref in local.group_client_role_refs : split("/", ref)[0]],
  ))
  unmanaged_role_containers = toset([
    for c in local.referenced_role_containers : c if !contains(keys(var.clients), c)
  ])
}

# realm_id is the realm NAME (see the override lookup above). With
# keycloak_realm.this.id here, any plan that also changed a realm setting
# deferred this read, left `client_id` of every service-account grant below
# unknown, and planned each grant on `realm-management` as destroy-and-create.
data "keycloak_openid_client" "role_container" {
  for_each = local.unmanaged_role_containers

  realm_id  = var.realm
  client_id = each.value
}

locals {
  role_container_ids = merge(
    { for k, c in keycloak_openid_client.this : k => c.id },
    { for k, c in data.keycloak_openid_client.role_container : k => c.id },
  )
}

# `default-roles-<realm>` is implicitly on every service account and is not
# declared; `uma_protection` on the client's own authorization server is
# auto-granted and not declared either.
resource "keycloak_openid_client_service_account_realm_role" "this" {
  for_each = local.sa_realm_roles

  realm_id                = keycloak_realm.this.id
  service_account_user_id = keycloak_openid_client.this[each.value.client].service_account_user_id
  role                    = each.value.role

  depends_on = [keycloak_role.realm, keycloak_role.realm_composite]
}

resource "keycloak_openid_client_service_account_role" "this" {
  for_each = local.sa_client_roles

  realm_id                = keycloak_realm.this.id
  service_account_user_id = keycloak_openid_client.this[each.value.client].service_account_user_id
  client_id               = local.role_container_ids[each.value.container]
  role                    = each.value.role

  depends_on = [keycloak_role.client]
}
