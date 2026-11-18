output "vault_ids" {
  description = "Vault name => resource ID."
  value       = { for name, kv in azurerm_key_vault.kv : name => kv.id }
}

output "vault_uris" {
  description = "Vault name => data-plane URI."
  value       = { for name, kv in azurerm_key_vault.kv : name => kv.vault_uri }
}
