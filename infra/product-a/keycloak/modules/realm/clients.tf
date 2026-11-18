# Every client in this module declares valid_redirect_uris,
# valid_post_logout_redirect_uris, web_origins and frontchannel_logout_enabled
# explicitly, `[]` included. The provider marks all four Optional+Computed: leaving
# one out does not mean "none", it means "keep whatever live has", and a hand edit
# in the console never shows up in `tofu plan`.

# --- product-a-web: the public SPA ------------------------------------------------

resource "keycloak_openid_client" "web" {
  realm_id    = local.realm_id
  client_id   = "product-a-web"
  name        = "Product A web"
  description = "Public SPA client."
  enabled     = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = false
  pkce_code_challenge_method   = "S256"

  root_url  = var.canonical_app_url
  base_url  = var.canonical_app_url
  admin_url = var.canonical_app_url

  # Lists rather than one derived origin: prod serves more than one hostname and
  # each must be a valid redirect target and CORS origin.
  valid_redirect_uris             = var.app_redirect_uris
  valid_post_logout_redirect_uris = var.app_redirect_uris
  web_origins                     = var.app_web_origins

  frontchannel_logout_enabled = true
  frontchannel_logout_url     = var.canonical_app_url

  full_scope_allowed = true
  consent_required   = false
}

resource "keycloak_openid_client_default_scopes" "web" {
  realm_id       = local.realm_id
  client_id      = keycloak_openid_client.web.id
  default_scopes = local.web_default_scopes

  depends_on = [keycloak_openid_client_scope.marker]
}

# Because this resource PUTs the whole list, dropping offline_access has to be
# deliberate and stay deliberate -- hence the setsubtract in locals.tf.
resource "keycloak_openid_client_optional_scopes" "web" {
  realm_id        = local.realm_id
  client_id       = keycloak_openid_client.web.id
  optional_scopes = local.web_optional_scopes
}

# --- product-a-api: the backend ----------------------------------------------------

resource "keycloak_openid_client" "api" {
  realm_id  = local.realm_id
  client_id = "product-a-api"
  name      = "Product A backend services"
  enabled   = true

  access_type = "CONFIDENTIAL"

  # DERIVED, not declared: an authorization-code flow with no redirect URI cannot
  # complete a login, and the provider rejects that pair on every create AND
  # update. Deriving the flag makes the invalid combination unrepresentable.
  standard_flow_enabled        = length(var.api_redirect_uris) > 0
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = true

  valid_redirect_uris             = var.api_redirect_uris
  valid_post_logout_redirect_uris = []
  web_origins                     = []

  frontchannel_logout_enabled = true

  full_scope_allowed = true
  consent_required   = false
}

resource "keycloak_openid_client_default_scopes" "api" {
  realm_id       = local.realm_id
  client_id      = keycloak_openid_client.api.id
  default_scopes = local.default_service_account
}

# Writes and reads the audit trail, so it carries all three audit scopes.
resource "keycloak_openid_client_optional_scopes" "api" {
  realm_id        = local.realm_id
  client_id       = keycloak_openid_client.api.id
  optional_scopes = concat(local.oidc_optional_baseline, keys(local.audit_scopes))

  depends_on = [keycloak_openid_client_scope.audit]
}

# --- product-a-mcp-data: M2M ---------------------------------------------------------
# mcp-data:read is a DEFAULT scope here, not optional: the client always gets it.

resource "keycloak_openid_client" "mcp_data" {
  realm_id    = local.realm_id
  client_id   = "product-a-mcp-data"
  description = "M2M client for workers calling the data MCP server (scope mcp-data:read)."
  enabled     = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = false
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = true

  valid_redirect_uris             = []
  valid_post_logout_redirect_uris = []
  web_origins                     = []
  frontchannel_logout_enabled     = false

  full_scope_allowed = true
  consent_required   = false
}

resource "keycloak_openid_client_default_scopes" "mcp_data" {
  realm_id       = local.realm_id
  client_id      = keycloak_openid_client.mcp_data.id
  default_scopes = concat(local.default_service_account, ["mcp-data:read"])

  depends_on = [keycloak_openid_client_scope.mcp_data_read]
}

resource "keycloak_openid_client_optional_scopes" "mcp_data" {
  realm_id        = local.realm_id
  client_id       = keycloak_openid_client.mcp_data.id
  optional_scopes = local.oidc_optional_baseline
}

# --- product-a-module: the Python module's service client ---------------------------
# The account-audience mapper is MANDATORY, not cosmetic: the services validate
# ValidAudience = "account", which client-credentials tokens do not carry by
# default (a long-standing Keycloak issue).

resource "keycloak_openid_client" "module" {
  realm_id    = local.realm_id
  client_id   = "product-a-module"
  description = "Service client for prompt-governance resolve calls."
  enabled     = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = false
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = true

  valid_redirect_uris             = []
  valid_post_logout_redirect_uris = []
  web_origins                     = []
  frontchannel_logout_enabled     = false

  full_scope_allowed = true
  consent_required   = false
}

resource "keycloak_openid_audience_protocol_mapper" "module_account" {
  realm_id  = local.realm_id
  client_id = keycloak_openid_client.module.id
  name      = "account-audience"

  included_client_audience   = "account"
  add_to_access_token        = true
  add_to_id_token            = false
  add_to_token_introspection = true
}

resource "keycloak_openid_client_default_scopes" "module" {
  realm_id       = local.realm_id
  client_id      = keycloak_openid_client.module.id
  default_scopes = local.default_service_account
}

resource "keycloak_openid_client_optional_scopes" "module" {
  realm_id        = local.realm_id
  client_id       = keycloak_openid_client.module.id
  optional_scopes = local.oidc_optional_baseline
}

# --- product-a-token-client ------------------------------------------------------------
# Authorization services are enabled but the resource server holds zero resources
# and zero policies; keep_defaults = false reproduces that. Keycloak itself creates
# the `uma_protection` client role and grants it to this service account whenever
# authorization services are on; the grant is listed in service-account-roles.tf
# so the exhaustive role set keeps it.

resource "keycloak_openid_client" "token_client" {
  realm_id  = local.realm_id
  client_id = "product-a-token-client"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = false
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = true

  # Must be declared EMPTY: with no browser flow, the provider rejects ANY update
  # to a client whose redirect URIs or web origins are non-empty -- and a list
  # holding one empty string, as the live dev client had, counts as non-empty.
  valid_redirect_uris             = []
  valid_post_logout_redirect_uris = []
  web_origins                     = []
  frontchannel_logout_enabled     = true

  full_scope_allowed = true
  consent_required   = false

  authorization {
    policy_enforcement_mode          = "ENFORCING"
    decision_strategy                = "UNANIMOUS"
    allow_remote_resource_management = true
    keep_defaults                    = false
  }
}

resource "keycloak_openid_client_default_scopes" "token_client" {
  realm_id       = local.realm_id
  client_id      = keycloak_openid_client.token_client.id
  default_scopes = local.default_service_account
}

resource "keycloak_openid_client_optional_scopes" "token_client" {
  realm_id        = local.realm_id
  client_id       = keycloak_openid_client.token_client.id
  optional_scopes = local.oidc_optional_baseline
}

# --- The two env-suffixed audit clients -------------------------------------------------

# Audience-only resource client: every flow off. It never logs in and never asks
# for a token; it exists so other clients' tokens can name it in `aud`.
resource "keycloak_openid_client" "audit" {
  realm_id    = local.realm_id
  client_id   = local.audit_client_id
  description = "Resource client for the audit service. Never logs in; exists so tokens can carry aud=${local.audit_client_id}."
  enabled     = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = false
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = false

  valid_redirect_uris             = []
  valid_post_logout_redirect_uris = []
  web_origins                     = []
  frontchannel_logout_enabled     = false

  full_scope_allowed = true
  consent_required   = false
}

resource "keycloak_openid_client_default_scopes" "audit" {
  realm_id       = local.realm_id
  client_id      = keycloak_openid_client.audit.id
  default_scopes = local.oidc_default_baseline
}

resource "keycloak_openid_client_optional_scopes" "audit" {
  realm_id        = local.realm_id
  client_id       = keycloak_openid_client.audit.id
  optional_scopes = local.oidc_optional_baseline
}

# Reads the audit trail and onboards tenants: log-query and audit-tenant-admin, but
# deliberately NOT log-ingest. It has no business writing audit events.
resource "keycloak_openid_client" "admin_api" {
  realm_id    = local.realm_id
  client_id   = local.admin_api_client_id
  description = "Confidential service client of the admin API: client_credentials to the audit service and to the Keycloak admin REST API."
  enabled     = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = false
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = true

  valid_redirect_uris             = []
  valid_post_logout_redirect_uris = []
  web_origins                     = []
  frontchannel_logout_enabled     = false

  full_scope_allowed = true
  consent_required   = false
}

resource "keycloak_openid_client_default_scopes" "admin_api" {
  realm_id       = local.realm_id
  client_id      = keycloak_openid_client.admin_api.id
  default_scopes = local.default_service_account
}

resource "keycloak_openid_client_optional_scopes" "admin_api" {
  realm_id        = local.realm_id
  client_id       = keycloak_openid_client.admin_api.id
  optional_scopes = concat(local.oidc_optional_baseline, ["log-query", "audit-tenant-admin"])

  depends_on = [keycloak_openid_client_scope.audit]
}
