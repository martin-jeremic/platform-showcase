output "realm_name" {
  description = "Realm these objects live in. Root resources reference this rather than var.realm_name: it carries the realm-before-clients dependency when manage_realm is true."
  value       = local.realm_id
}

output "client_ids" {
  description = "Logical name -> Keycloak clientId, so callers do not re-derive the env token."
  value = {
    web          = keycloak_openid_client.web.client_id
    api          = keycloak_openid_client.api.client_id
    mcp_data     = keycloak_openid_client.mcp_data.client_id
    module       = keycloak_openid_client.module.client_id
    token_client = keycloak_openid_client.token_client.client_id
    audit        = keycloak_openid_client.audit.client_id
    admin_api    = keycloak_openid_client.admin_api.client_id
  }
}

# Service-account user of each app client, keyed like keycloak_user_roles.service_account:
# a root imports that resource with "<realm>/<user id>".
output "service_account_user_ids" {
  description = "Service-account user id per app client, for importing keycloak_user_roles.service_account."
  value       = { for name, account in local.service_account_roles : name => account.user_id }
}

output "scope_profiles" {
  description = "Default/optional client-scope lists, so a root never re-types Keycloak's baseline."
  value = {
    default_baseline  = local.oidc_default_baseline
    optional_baseline = local.oidc_optional_baseline
  }
}

# No client secrets. A sensitive output is still plaintext in state and printed in
# full by `tofu output -json`; the secrets are read from the admin console or the
# client-secret endpoint and written straight into Key Vault.

output "audit_audience" {
  description = "Expected `aud` for the audit service in this realm. An empty value in the service config means it accepts no token at all."
  value       = keycloak_openid_client.audit.client_id
}
