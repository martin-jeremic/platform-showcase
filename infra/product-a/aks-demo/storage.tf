resource "azurerm_storage_account" "demo" {
  name                     = var.storage_account_name
  location                 = azurerm_resource_group.demo.location
  resource_group_name      = azurerm_resource_group.demo.name
  account_tier             = "Standard"
  account_replication_type = "LRS" # demo data is disposable
  access_tier              = "Hot"

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # Coupled to the operational blob backup in backup.tf, exactly as in prod: Azure
  # Backup turns point-in-time restore on when the backup instance is created, so
  # declaring the same values here stops the two from fighting on every plan. PITR
  # retention must be strictly shorter than soft delete, hence the +1.
  blob_properties {
    versioning_enabled  = true
    change_feed_enabled = true

    delete_retention_policy {
      days = var.blob_backup_retention_days + 1
    }

    container_delete_retention_policy {
      days = var.blob_backup_retention_days + 1
    }

    restore_policy {
      days = var.blob_backup_retention_days
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "loki_chunks" {
  name               = "loki-chunks"
  storage_account_id = azurerm_storage_account.demo.id
}

resource "azurerm_storage_container" "backups" {
  name               = "backups"
  storage_account_id = azurerm_storage_account.demo.id
}
