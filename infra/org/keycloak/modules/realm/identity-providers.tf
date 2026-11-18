# ---------------------------------------------------------------------------
# Brokered identity providers and their mappers
# ---------------------------------------------------------------------------

# SECRET HANDLING IS DIFFERENT FROM CLIENTS, AND IT MATTERS.
#
# For clients, `client_secret` is Optional+Computed and simply omitted. Both IdP
# resources REQUIRE it. Keycloak's admin API returns the literal "**********" for
# any IdP secret, so that mask is what an import writes into state; the module
# defaults the argument to the same mask so config and state agree, and pins the
# field with ignore_changes so tofu never writes it even if Keycloak's masking
# changes. On an update the provider sends the mask and Keycloak keeps the
# current secret.
#
# Net effect: this stack can never rotate or clobber a broker secret. To rotate
# deliberately: put the real value in `identity_provider_secrets` AND delete the
# lifecycle block, in one reviewed change.

locals {
  idp_secret_mask = "**********"

  oidc_identity_providers      = { for k, p in var.identity_providers : k => p if p.provider_id != "microsoft" }
  microsoft_identity_providers = { for k, p in var.identity_providers : k => p if p.provider_id == "microsoft" }

  identity_provider_mappers = merge([
    for alias, p in var.identity_providers : {
      for name, m in p.mappers : "${alias}/${name}" => merge(m, { alias = alias, name = name })
    }
  ]...)
}

# Generic OIDC broker (provider_id "oidc", or "keycloak-oidc" for another
# Keycloak realm). Every endpoint is explicit; deriving them from an issuer would
# hide a token endpoint pointing at a different realm than the authorization one.
resource "keycloak_oidc_identity_provider" "this" {
  for_each = local.oidc_identity_providers

  realm       = keycloak_realm.this.id
  alias       = each.key
  provider_id = each.value.provider_id

  display_name                  = each.value.display_name
  enabled                       = each.value.enabled
  store_token                   = each.value.store_token
  add_read_token_role_on_create = each.value.add_read_token_role_on_create
  authenticate_by_default       = each.value.authenticate_by_default
  link_only                     = each.value.link_only
  hide_on_login_page            = each.value.hide_on_login_page
  trust_email                   = each.value.trust_email
  first_broker_login_flow_alias = each.value.first_broker_login_flow_alias
  post_broker_login_flow_alias  = each.value.post_broker_login_flow_alias

  gui_order = each.value.gui_order
  sync_mode = each.value.sync_mode

  client_id     = each.value.client_id
  client_secret = lookup(var.identity_provider_secrets, each.key, local.idp_secret_mask)

  authorization_url = each.value.authorization_url
  token_url         = each.value.token_url
  user_info_url     = each.value.user_info_url
  jwks_url          = each.value.jwks_url
  logout_url        = each.value.logout_url
  issuer            = each.value.issuer
  login_hint        = each.value.login_hint

  backchannel_supported                   = each.value.backchannel_supported
  validate_signature                      = each.value.validate_signature
  ui_locales                              = each.value.ui_locales
  disable_user_info                       = each.value.disable_user_info
  disable_type_claim_check                = each.value.disable_type_claim_check
  default_scopes                          = each.value.default_scopes
  accepts_prompt_none_forward_from_client = each.value.accepts_prompt_none_forward_from_client

  # Only keys WITHOUT a first-class argument may go here (clientAuthMethod,
  # pkceEnabled, showInAccountConsole, ...). The provider rejects the rest.
  extra_config = length(each.value.extra_config) > 0 ? each.value.extra_config : null

  # A custom first-broker-login flow must exist before the broker that binds it.
  depends_on = [keycloak_authentication_flow.this]

  lifecycle {
    ignore_changes = [client_secret]
  }
}

resource "keycloak_oidc_microsoft_identity_provider" "this" {
  for_each = local.microsoft_identity_providers

  realm       = keycloak_realm.this.id
  alias       = each.key
  provider_id = each.value.provider_id

  display_name                  = each.value.display_name
  enabled                       = each.value.enabled
  store_token                   = each.value.store_token
  add_read_token_role_on_create = each.value.add_read_token_role_on_create
  authenticate_by_default       = each.value.authenticate_by_default
  link_only                     = each.value.link_only
  hide_on_login_page            = each.value.hide_on_login_page
  trust_email                   = each.value.trust_email
  first_broker_login_flow_alias = each.value.first_broker_login_flow_alias
  post_broker_login_flow_alias  = each.value.post_broker_login_flow_alias

  gui_order = each.value.gui_order
  sync_mode = each.value.sync_mode

  client_id     = each.value.client_id
  client_secret = lookup(var.identity_provider_secrets, each.key, local.idp_secret_mask)
  tenant_id     = each.value.tenant_id
  prompt        = each.value.prompt

  default_scopes                          = each.value.default_scopes
  accepts_prompt_none_forward_from_client = each.value.accepts_prompt_none_forward_from_client
  disable_user_info                       = each.value.disable_user_info

  extra_config = length(each.value.extra_config) > 0 ? each.value.extra_config : null

  depends_on = [keycloak_authentication_flow.this]

  lifecycle {
    ignore_changes = [client_secret]
  }
}

# Always the generic mapper resource with the config verbatim: the typed IdP
# mapper resources do not cover every mapper type Keycloak ships
# (`microsoft-user-attribute-mapper`, `oidc-advanced-group-idp-mapper`), and the
# generic one round-trips the config map exactly.
resource "keycloak_custom_identity_provider_mapper" "this" {
  for_each = local.identity_provider_mappers

  realm                    = keycloak_realm.this.id
  name                     = each.value.name
  identity_provider_alias  = each.value.alias
  identity_provider_mapper = each.value.identity_provider_mapper
  extra_config             = each.value.config

  depends_on = [
    keycloak_oidc_identity_provider.this,
    keycloak_oidc_microsoft_identity_provider.this,
  ]
}
