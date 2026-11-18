# The realm object and its singletons. Adopted by import (id = realm name), then
# owned. Two independent guards:
#   * prevent_destroy blocks any plan that would destroy the realm while this block
#     exists;
#   * terraform_deletion_protection makes the PROVIDER refuse the delete even if the
#     module call is removed from the root -- the case prevent_destroy cannot cover,
#     because the lifecycle block disappears with the resource.
#
# Expected on the first plan after import: one in-place change per realm,
# terraform_deletion_protection false -> true. The flag lives only in state and the
# import Read cannot see config, so it lands as false. The same update shows
# `attributes` and `security_defenses` as additions: the import Read fills neither
# (attributes are tracked per configured key, and there are none yet). The update
# PUTs the realm with the values below, which are the live values by construction.
resource "keycloak_realm" "this" {
  realm   = var.realm
  enabled = var.settings.enabled

  display_name = var.settings.display_name

  registration_allowed           = var.settings.registration_allowed
  registration_email_as_username = var.settings.registration_email_as_username
  edit_username_allowed          = var.settings.edit_username_allowed
  reset_password_allowed         = var.settings.reset_password_allowed
  remember_me                    = var.settings.remember_me
  verify_email                   = var.settings.verify_email
  login_with_email_allowed       = var.settings.login_with_email_allowed
  duplicate_emails_allowed       = var.settings.duplicate_emails_allowed
  ssl_required                   = var.settings.ssl_required

  default_signature_algorithm  = var.settings.default_signature_algorithm
  revoke_refresh_token         = var.settings.revoke_refresh_token
  sso_session_idle_timeout     = var.settings.sso_session_idle_timeout
  sso_session_max_lifespan     = var.settings.sso_session_max_lifespan
  offline_session_idle_timeout = var.settings.offline_session_idle_timeout
  access_token_lifespan        = var.settings.access_token_lifespan
  access_code_lifespan         = var.settings.access_code_lifespan

  # Flow bindings are always written by the exporter: when they are absent the
  # provider falls back to the built-in names, which would RE-BIND a realm that
  # uses a custom flow.
  browser_flow               = var.settings.browser_flow
  registration_flow          = var.settings.registration_flow
  direct_grant_flow          = var.settings.direct_grant_flow
  reset_credentials_flow     = var.settings.reset_credentials_flow
  client_authentication_flow = var.settings.client_authentication_flow
  docker_authentication_flow = var.settings.docker_authentication_flow
  first_broker_login_flow    = var.settings.first_broker_login_flow

  # A curated allowlist (frontendUrl, acr.loa.map, ...), never the whole live map:
  # the provider tracks only the keys listed, and an empty string means "delete".
  attributes = var.settings.attributes

  # default_default_client_scopes / default_optional_client_scopes are NOT set:
  # GET /realms/{realm} never returns them, so the provider reads them as empty and
  # any configured value is a perpetual diff. They have their own resources below.

  # Security headers are always written: without the block the provider sends its
  # own defaults on every update, overwriting a realm whose headers were tuned by
  # hand. Brute-force protection is ON only when brute_force_detection is present.
  dynamic "security_defenses" {
    for_each = var.settings.security_headers == null && var.settings.brute_force_detection == null ? [] : [1]
    content {
      dynamic "headers" {
        for_each = var.settings.security_headers == null ? [] : [var.settings.security_headers]
        content {
          x_frame_options                     = headers.value.x_frame_options
          content_security_policy             = headers.value.content_security_policy
          content_security_policy_report_only = headers.value.content_security_policy_report_only
          x_content_type_options              = headers.value.x_content_type_options
          x_robots_tag                        = headers.value.x_robots_tag
          x_xss_protection                    = headers.value.x_xss_protection
          strict_transport_security           = headers.value.strict_transport_security
          referrer_policy                     = headers.value.referrer_policy
        }
      }

      dynamic "brute_force_detection" {
        for_each = var.settings.brute_force_detection == null ? [] : [var.settings.brute_force_detection]
        content {
          permanent_lockout          = brute_force_detection.value.permanent_lockout
          max_login_failures         = brute_force_detection.value.max_login_failures
          wait_increment_seconds     = brute_force_detection.value.wait_increment_seconds
          max_failure_wait_seconds   = brute_force_detection.value.max_failure_wait_seconds
          failure_reset_time_seconds = brute_force_detection.value.failure_reset_time_seconds
        }
      }
    }
  }

  terraform_deletion_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

# Realm-level default and optional client scopes: what a NEW client gets attached.
# Importable by realm id. Both RECONCILE the live marking against the list, so the
# lists are the complete live sets, built-ins included.
resource "keycloak_realm_default_client_scopes" "this" {
  count = var.default_client_scopes == null ? 0 : 1

  realm_id       = keycloak_realm.this.id
  default_scopes = var.default_client_scopes

  depends_on = [keycloak_openid_client_scope.this]
}

resource "keycloak_realm_optional_client_scopes" "this" {
  count = var.optional_client_scopes == null ? 0 : 1

  realm_id        = keycloak_realm.this.id
  optional_scopes = var.optional_client_scopes

  depends_on = [keycloak_openid_client_scope.this]
}

# The composite default-roles-<realm>. Editing this set is how an over-broad default
# (realm-management roles granted to every user) gets fixed -- as its own change
# after adoption, never inside it.
resource "keycloak_default_roles" "this" {
  count = var.default_roles == null ? 0 : 1

  realm_id      = keycloak_realm.this.id
  default_roles = var.default_roles
}
