locals {
  # Every child resource references this, never var.realm_name directly.
  #
  # manage_realm = false -> a plain string, known at plan time, so an EXISTING
  #                         realm imports cleanly with no keycloak_realm in state.
  # manage_realm = true  -> the realm resource's id, which creates the implicit
  #                         dependency edge that orders realm-before-clients. A bare
  #                         string would not, and a greenfield apply would race to
  #                         create clients in a realm that does not exist yet.
  realm_id = var.manage_realm ? keycloak_realm.this[0].id : var.realm_name

  # The only two client ids that vary per environment. The suffix is load-bearing:
  # the audience mapper on the audit scopes names this id, and the audit service
  # validates that exact string as `aud`.
  audit_client_id     = "product-a-audit-${var.env}"
  admin_api_client_id = "product-a-admin-api-${var.env}"

  audit_audience_mapper_name = "aud-${local.audit_client_id}"

  # ---------------------------------------------------------------------------
  # Client scope profiles
  #
  # keycloak_openid_client_{default,optional}_scopes are AUTHORITATIVE: the resource
  # PUTs exactly the list and silently DETACHES anything omitted. So these must
  # enumerate Keycloak's own baseline too, not just our additions.
  #
  # `role_list` and `saml_organization` are in the realm's default set but are
  # SAML-only, so they never attach to an OIDC client and must not appear here.
  # `service_account` is a Keycloak built-in (verified against an untouched master
  # realm), attached automatically to every service-account client.
  # ---------------------------------------------------------------------------
  oidc_default_baseline  = ["acr", "basic", "email", "profile", "roles", "web-origins"]
  oidc_optional_baseline = ["address", "microprofile-jwt", "offline_access", "organization", "phone"]

  default_service_account = concat(local.oidc_default_baseline, ["service_account"])

  # The SPA is the one client that REMOVES a baseline entry. Expressed as a
  # subtraction so the intent survives the next person editing the baseline.
  web_default_scopes  = concat(local.oidc_default_baseline, local.marker_scopes)
  web_optional_scopes = setsubtract(local.oidc_optional_baseline, ["offline_access"])

  # The three audit scopes. Descriptions stay short: on an MSSQL-backed Keycloak
  # CLIENT_SCOPE.DESCRIPTION is varchar(255), and an overflow fails as an opaque
  # HTTP 500 that names neither field nor limit.
  audit_scopes = {
    "log-ingest"         = "Write one audit event (POST /api/log-ingest/*)."
    "log-query"          = "Read the audit trail (GET /api/log-query/*). Separate from log-ingest: a caller that may write must not automatically be able to read."
    "audit-tenant-admin" = "Onboard a tenant into the audit registry. Strictly more power than writing or reading; never granted to a tenant admin."
  }

  # Marker scopes: no mappers, no description, not in the `scope` claim. They exist
  # so the SPA can carry them as defaults.
  marker_scopes = ["openid", "user_name", "user_role"]

  # Flat, membership-only groups, one per numeric tenant id, read out of the token
  # by the `groups` scope mapper.
  tenant_groups = ["1001", "1002", "1003"]

  # Realm roles we own. default-roles-<realm>, offline_access and uma_authorization
  # are Keycloak built-ins and stay unmanaged.
  realm_roles = {
    superadmin                = ""
    platform_admin            = ""
    prompt_governance_service = "M2M role: read-only prompt-governance resolve plus execution telemetry."
  }
}
