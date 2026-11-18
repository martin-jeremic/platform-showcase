output "realm_id" {
  description = "Realm name, which is also the provider's realm id."
  value       = keycloak_realm.this.id
}

output "realm_internal_id" {
  description = "Keycloak's internal UUID of the realm."
  value       = keycloak_realm.this.internal_id
}

output "client_ids" {
  description = "Internal UUID of every managed client, keyed by clientId."
  value       = { for k, c in keycloak_openid_client.this : k => c.id }
}

output "service_account_user_ids" {
  description = "Service-account user id of every client that has one, keyed by clientId."
  value       = { for k, c in keycloak_openid_client.this : k => c.service_account_user_id if c.service_accounts_enabled }
}

output "client_scope_ids" {
  description = "Internal UUID of every managed custom client scope, keyed by name."
  value       = { for k, s in keycloak_openid_client_scope.this : k => s.id }
}

output "group_ids" {
  description = "Internal UUID of every managed group, keyed by name."
  value       = { for k, g in keycloak_group.this : k => g.id }
}

# No client secret is exposed. A sensitive output is still plaintext in state
# and printed in full by `tofu output -json`; read secrets from the admin console
# or the client-secret endpoint and put them straight into Key Vault.
