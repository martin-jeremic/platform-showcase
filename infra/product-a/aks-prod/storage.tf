resource "azurerm_storage_account" "prod" {
  name                = var.storage_account_name
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  account_tier        = "Standard"
  access_tier         = "Hot"

  # Immutable in practice, hence its own variable rather than var.ha.
  account_replication_type = var.storage_replication_type

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # Account keys can go once nothing uses one. The source left this on with a
  # "verify Loki is on workload identity first" note; identity-workload.tf is that
  # move. Diagnostic settings and Azure Backup reach the account as trusted
  # services, not with keys. With keys off, the provider must create containers
  # with Entra auth (storage_use_azuread in main.tf), and the applier needs a blob
  # data-plane role -- Owner/Contributor carry no dataActions.
  shared_access_key_enabled = var.storage_shared_key_enabled

  # These settings are coupled to the operational blob backup in backup.tf. Azure
  # Backup enables point-in-time restore when the backup instance is created;
  # declaring the same values here keeps OpenTofu and the backup service from
  # fighting on every plan. PITR retention must be strictly LESS than soft-delete
  # retention, hence the +1.
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

  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

resource "azurerm_storage_container" "backups" {
  name               = "backups"
  storage_account_id = azurerm_storage_account.prod.id
}

# --- Observability object storage ----------------------------------------------
# Loki and Tempo keep ALL their data in blob; their PVCs hold only the WAL.
#
# The names are not free choices; each is a literal in the observability chart
# values (loki.storage.bucketNames.chunks / .ruler, tempo...container_name).
#
# They did not exist at first, and a single `loki` container is not what the chart
# asks for. That was the direct cause of a Loki crash loop: it died initialising
# the ruler-storage module, which opens the ruler container. A missing container
# is not auto-created; the SDK returns ContainerNotFound and Loki refuses to start.
#
# Retention is a storage LIFECYCLE POLICY, not a chart value: Loki's
# retention_period only marks chunks deleted. Keep the lifecycle window >= the
# chart's retention, or blob removes chunks Loki still believes it has.

resource "azurerm_storage_container" "loki_chunks" {
  name               = "loki-chunks"
  storage_account_id = azurerm_storage_account.prod.id
}

# Unused while rules ship through the Loki sidecar into the ruler's local directory
# (platform/charts/observability). Kept so moving rules to object storage is a values change,
# not an apply that has to land before the chart.
resource "azurerm_storage_container" "loki_ruler" {
  name               = "loki-ruler"
  storage_account_id = azurerm_storage_account.prod.id
}

resource "azurerm_storage_container" "tempo_traces" {
  name               = "tempo-traces"
  storage_account_id = azurerm_storage_account.prod.id
}

resource "azurerm_storage_management_policy" "observability" {
  storage_account_id = azurerm_storage_account.prod.id

  rule {
    name    = "observability-retention"
    enabled = true

    filters {
      prefix_match = ["loki-chunks/", "tempo-traces/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.observability_retention_days
      }
    }
  }
}
