output "server_fqdn" {
  description = "FQDN of the logical server."
  value       = azurerm_mssql_server.sql.fully_qualified_domain_name
}

output "database_ids" {
  description = "Database name => resource ID."
  value       = { for name, db in azurerm_mssql_database.db : name => db.id }
}
