# The realm itself -- adopted LAST, behind var.manage_realm.
#
# keycloak_realm resets every attribute it does not declare to the provider's
# default rather than leaving it alone, across dozens of attributes. That makes it
# the single riskiest resource here, so an existing realm runs with
# manage_realm = false until every leaf object already plans clean; only then is
# the realm imported and driven to an empty plan on its own.
#
# Values are the live settings, verified identical across the adopted realms.
# Lifespans are Go duration strings; the API reports seconds.

resource "keycloak_realm" "this" {
  count = var.manage_realm ? 1 : 0

  realm   = var.realm_name
  enabled = true

  # registration_allowed is OPEN SELF-REGISTRATION. The module defaults it to the
  # live dev value; prod passes false (see the variable).
  ssl_required                   = "external"
  registration_allowed           = var.registration_allowed
  registration_email_as_username = false
  remember_me                    = false
  verify_email                   = false
  login_with_email_allowed       = true
  duplicate_emails_allowed       = false
  reset_password_allowed         = false
  edit_username_allowed          = false

  access_token_lifespan                   = "10m"
  access_token_lifespan_for_implicit_flow = "15m"
  sso_session_idle_timeout                = "30m"
  sso_session_max_lifespan                = "10h"
  offline_session_idle_timeout            = "720h"
  access_code_lifespan                    = "3m"
  action_token_generated_by_user_lifespan = "5m"
  revoke_refresh_token                    = false

  default_signature_algorithm = "RS256"

  # Stock flows only; no custom authentication flows exist in these realms.
  browser_flow               = "browser"
  direct_grant_flow          = "direct grant"
  client_authentication_flow = "clients"
  docker_authentication_flow = "docker auth"
  registration_flow          = "registration"
  reset_credentials_flow     = "reset credentials"

  # Brute-force protection on. This was an open finding on the live realms; it is
  # set here rather than left as a provider default so the posture is readable.
  security_defenses {
    brute_force_detection {
      max_login_failures         = 10
      wait_increment_seconds     = 60
      max_failure_wait_seconds   = 900
      failure_reset_time_seconds = 43200
    }
  }

  # With the realm managed, removing the module call must not be able to delete
  # it: the provider refuses the delete while this flag is set, which covers the
  # case prevent_destroy cannot (the lifecycle block disappears with the resource).
  terraform_deletion_protection = true

  lifecycle {
    prevent_destroy = true
  }
}
