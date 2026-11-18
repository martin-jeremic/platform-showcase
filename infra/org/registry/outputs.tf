output "registry_ids" {
  description = "Registry name => resource ID."
  value       = { for name, acr in azurerm_container_registry.acr : name => acr.id }
}

output "login_servers" {
  description = "Registry name => login server."
  value       = { for name, acr in azurerm_container_registry.acr : name => acr.login_server }
}
