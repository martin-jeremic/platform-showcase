output "server_fqdn" {
  description = "FQDN to connect to."
  value       = azurerm_postgresql_flexible_server.pg.fqdn
}

output "database_names" {
  description = "Databases on the server."
  value       = sort([for db in azurerm_postgresql_flexible_server_database.databases : db.name])
}

# No connection-string outputs. The source exported admin connection strings per
# database (sensitive, but still plaintext in `tofu output -json`). Applications
# get their own role and read its password from Key Vault (app-roles.tf).
output "app_password_secrets" {
  description = "Per application role: the vault object holding its password."
  value       = { for k, s in azurerm_key_vault_secret.app_password : k => s.name }
}
