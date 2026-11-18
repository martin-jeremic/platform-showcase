resource "azurerm_data_protection_backup_vault" "demo" {
  name                = "bvault-product-a-demo"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  datastore_type      = "VaultStore"
  redundancy          = "LocallyRedundant" # demo data is disposable

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

# --- Role assignments the vault identity needs before a backup instance can be
# --- created. RBAC propagation is the classic failure here; see the long note on
# --- the same sleep in ../aks-prod/backup.tf for why it is minutes, not seconds.

resource "azurerm_role_assignment" "vault_reader_rg" {
  scope                = azurerm_resource_group.demo.id
  role_definition_name = "Reader"
  principal_id         = azurerm_data_protection_backup_vault.demo.identity[0].principal_id
}

resource "azurerm_role_assignment" "vault_storage_backup_contributor" {
  scope                = azurerm_storage_account.demo.id
  role_definition_name = "Storage Account Backup Contributor"
  principal_id         = azurerm_data_protection_backup_vault.demo.identity[0].principal_id
}

resource "time_sleep" "rbac_propagation" {
  create_duration = "300s"

  depends_on = [
    azurerm_role_assignment.vault_reader_rg,
    azurerm_role_assignment.vault_storage_backup_contributor,
  ]
}

# --- PostgreSQL: no vaulted backup here, by decision. The demo database lives in
# a different region from this vault (var.dblocation), and a Data Protection vault
# can only protect a Flexible Server in its own region. The server's own 7-day
# backup is the demo's recovery path; prod has the full vaulted LTR setup.

# --- Blob storage: operational backup. Retention is shared with the storage
# account's point-in-time-restore window (storage.tf); change the variable, never
# one side of it.

resource "azurerm_data_protection_backup_policy_blob_storage" "blob" {
  name                                   = "bkpol-blob-product-a-demo"
  vault_id                               = azurerm_data_protection_backup_vault.demo.id
  operational_default_retention_duration = "P${var.blob_backup_retention_days}D"
}

resource "azurerm_data_protection_backup_instance_blob_storage" "blob" {
  name               = var.storage_account_name
  location           = azurerm_resource_group.demo.location
  vault_id           = azurerm_data_protection_backup_vault.demo.id
  storage_account_id = azurerm_storage_account.demo.id
  backup_policy_id   = azurerm_data_protection_backup_policy_blob_storage.blob.id

  depends_on = [time_sleep.rbac_propagation]
}
