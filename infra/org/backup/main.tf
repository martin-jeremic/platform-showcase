# Off-cluster storage for MongoDB backups.
#
# The MongoDB this protects is self-hosted in the aks-org-prod cluster, on a PVC.
# Unlike a managed database it has no platform backup of any kind -- lose the PVC
# and the data is gone. `mongodump` output landing here is
# the entire recovery path.
#
# Deliberately its own stack rather than resources inside ../aks-prod. That stack is
# the disposable one: per-folder `tofu destroy` is normal teardown there, and the
# cluster is meant to be rebuildable. A backup that a
# cluster destroy can delete is not a backup. ../../tfstate-bootstrap already makes this
# argument for state ("a dedicated RG ... so that a `tofu destroy` of any stack can
# never reach the state that describes it"); the same reasoning applies here, with more
# force, because state can be reconstructed by import and a dump cannot.

resource "azurerm_resource_group" "backup" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_storage_account" "backup" {
  name                = var.storage_account_name
  resource_group_name = azurerm_resource_group.backup.name
  location            = azurerm_resource_group.backup.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.replication_type
  access_tier              = "Hot"

  # Hardening: TLS 1.2 floor, HTTPS only, and no chance of a public blob.
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # No account keys, at all. A storage account key is a bearer credential that grants
  # full data-plane control including delete, with no Entra identity behind it -- which
  # would make the least-privilege role in identity-access.tf decorative, since anyone
  # who could call listKeys would have a way around it. Everything that writes or reads
  # here authenticates as a managed identity instead.
  #
  # Practical consequence: `az storage blob ...` commands against this account must pass
  # `--auth-mode login`. The default (key lookup) fails with a permissions error that
  # does not mention this setting.
  shared_access_key_enabled = false

  # Versioning is load-bearing, not housekeeping. The backup identity holds blob `write`
  # but not `delete` (identity-access.tf), and `write` can still overwrite an existing
  # blob name -- so overwriting is the one destructive move left open to a compromised
  # backup pod. With versioning on, an overwrite preserves the previous content as a
  # recoverable version, which closes that gap. Do not remove it.
  #
  # Soft delete covers the other direction: an accidental deletion by a human or a
  # script holding rights the backup job does not have.
  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.soft_delete_days
    }

    container_delete_retention_policy {
      days = var.soft_delete_days
    }
  }

  tags = var.tags
}

resource "azurerm_storage_container" "mongo" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.backup.id
  container_access_type = "private"
}

# Retention lives here and nowhere else.
#
# The backup identity has no `delete` data action, so the CronJob physically cannot
# prune its own old dumps -- that is the intended design, because an identity that can
# tidy up is an identity that can erase the history. The trade-off is that if this
# policy is wrong or absent, backups accumulate until the bill notices. Treat
# var.retention_days as the real retention requirement.
#
# Archive tier is avoided on purpose: rehydrating an archived blob takes hours, which
# is precisely the wrong property for the copy you reach for during an outage.
resource "azurerm_storage_management_policy" "backup" {
  storage_account_id = azurerm_storage_account.backup.id

  rule {
    name    = "mongo-backup-lifecycle"
    enabled = true

    filters {
      prefix_match = ["${azurerm_storage_container.mongo.name}/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than = var.tier_to_cool_days
        tier_to_cold_after_days_since_modification_greater_than = var.tier_to_cold_days
        delete_after_days_since_modification_greater_than       = var.retention_days
      }

      # Versions exist only because a dump overwrote an existing blob name. They are
      # worth keeping for a while as the anti-tamper net described above, but they are
      # not the primary copy and should not be retained as long as one.
      version {
        delete_after_days_since_creation = var.version_retention_days
      }
    }
  }
}

# Guards against deleting the account that holds the only copy of the Mongo data.
#
# Requires Microsoft.Authorization/locks/write (Owner or User Access Administrator).
# Plain Contributor cannot create this. If apply fails here, comment this resource out,
# finish the apply, and add the lock once rights are sorted -- everything else works
# without it.
#
# Note this also blocks a deliberate `tofu destroy` of this stack until the lock is
# removed. That is the intended trade-off: destroying this stack should be a decision
# someone makes twice.
resource "azurerm_management_lock" "backup" {
  name       = "backup-no-delete"
  scope      = azurerm_storage_account.backup.id
  lock_level = "CanNotDelete"
  notes      = "Holds the only backups of the self-hosted MongoDB in aks-org-prod. Deleting this account has no undo."
}
