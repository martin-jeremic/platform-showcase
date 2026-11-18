resource "azurerm_data_protection_backup_vault" "prod" {
  name                = "bvault-product-a-prod"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  datastore_type      = "VaultStore"

  # Immutable after create, hence its own variable rather than var.ha.
  redundancy = var.backup_vault_redundancy

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

# --- Role assignments the vault identity needs before backup instances exist ----

resource "azurerm_role_assignment" "vault_reader_rg" {
  scope                = azurerm_resource_group.prod.id
  role_definition_name = "Reader"
  principal_id         = azurerm_data_protection_backup_vault.prod.identity[0].principal_id
}

resource "azurerm_role_assignment" "vault_pg_ltr_backup" {
  scope                = azurerm_postgresql_flexible_server.pg.id
  role_definition_name = "PostgreSQL Flexible Server Long Term Retention Backup Role"
  principal_id         = azurerm_data_protection_backup_vault.prod.identity[0].principal_id
}

resource "azurerm_role_assignment" "vault_storage_backup_contributor" {
  scope                = azurerm_storage_account.prod.id
  role_definition_name = "Storage Account Backup Contributor"
  principal_id         = azurerm_data_protection_backup_vault.prod.identity[0].principal_id
}

resource "time_sleep" "rbac_propagation" {
  # 5 minutes, not the 30 s this started with. RBAC propagation regularly takes
  # minutes, and a backup instance created before the vault identity's role is
  # visible fails as `unexpected status 406 (406 Not Acceptable) received with no
  # body` -- an empty-bodied rejection from ValidateForBackup that names nothing and
  # reads like a provider bug. It is not; it is a race.
  #
  # THAT SAME 406 HAS A SECOND, UNRELATED CAUSE, and the two are indistinguishable
  # from the error text. If the vault already holds a SOFT-DELETED backup instance
  # for the datasource, Azure refuses to protect it again ("Azure Backup doesn't
  # allow the reconfiguration of a backup item to the same vault if the backup item
  # is already in a soft-deleted state"). Deleting an instance tombstones it for the
  # vault's soft-delete retention, and the tombstone does NOT appear under
  # backupInstances; it lives under deletedBackupInstances. On a 406, look there:
  #
  #   v="https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-product-a-prod/providers/Microsoft.DataProtection/backupVaults/bvault-product-a-prod"
  #   az rest --method get --url "$v/deletedBackupInstances?api-version=2024-04-01"
  #
  # Recovery is undelete + resume + import, not waiting out the retention:
  #
  #   az rest --method post --url "$v/deletedBackupInstances/psql-product-a-prod/undelete?api-version=2024-04-01"
  #   az rest --method post --url "$v/backupInstances/psql-product-a-prod/resumeProtection?api-version=2024-04-01"
  #   tofu import -var-file=prod.tfvars \
  #     azurerm_data_protection_backup_instance_postgresql_flexible_server.pg \
  #     "$v/backupInstances/psql-product-a-prod"
  #
  # Undelete lands in ProtectionStopped, so resumeProtection is NOT optional -- skip
  # it and the weekly backup silently never runs. The postcondition on the instance
  # below turns that silence into a failed plan.
  #
  # Five minutes on a create-only path is worth it: it removes the race, and the
  # race's own failure mode is what leaves the tombstone behind.
  create_duration = "300s"

  depends_on = [
    azurerm_role_assignment.vault_reader_rg,
    azurerm_role_assignment.vault_pg_ltr_backup,
    azurerm_role_assignment.vault_storage_backup_contributor,
  ]
}

# --- PostgreSQL: weekly vaulted long-term-retention backup ----------------------
# A second, independent copy on top of the server's own backup_retention_days
# (postgres.tf): that one dies with the server, this one survives it.

# The anchor is DERIVED, not written down. Azure rejects a policy whose first
# occurrence is in the past, so a literal date in this file is a bug with a timer
# on it: it works until the day someone rebuilds the environment. (The source had
# exactly such literals; one expired months before anyone noticed.)
#
# time_static captures the first apply and never moves again, so the value is
# stable in state. From that instant roll forward to the next Sunday 02:00 UTC,
# one hour before the server's maintenance window. Sunday maps to 7, not 0, on
# purpose: an apply on a Sunday must land on the NEXT Sunday, never today, or the
# anchor can be in the past by minutes.
resource "time_static" "pg_backup_anchor" {}

locals {
  days_to_next_sunday = {
    Sunday    = 7
    Monday    = 6
    Tuesday   = 5
    Wednesday = 4
    Thursday  = 3
    Friday    = 2
    Saturday  = 1
  }

  pg_backup_anchor = formatdate("YYYY-MM-DD'T'02:00:00+00:00", timeadd(
    time_static.pg_backup_anchor.rfc3339,
    "${local.days_to_next_sunday[formatdate("EEEE", time_static.pg_backup_anchor.rfc3339)] * 24}h",
  ))
}

resource "azurerm_data_protection_backup_policy_postgresql_flexible_server" "pg" {
  # Every argument on this resource is ForceNew (the provider defines no Update),
  # so changing the retention tiers REPLACES the policy -- and Azure refuses to
  # delete a policy a backup instance still references. create_before_destroy plus
  # a NEW name is what makes that one clean apply: new policy created, instance
  # repointed (backup_policy_id is not ForceNew, so the instance is UPDATED and the
  # tombstone trap above is never entered), old policy deleted last. Bump the
  # suffix whenever the tiers change.
  name     = "bkpol-psql-product-a-prod-ltr-v2"
  vault_id = azurerm_data_protection_backup_vault.prod.id

  backup_repeating_time_intervals = ["R/${local.pg_backup_anchor}/P1W"]

  # Near term: the window in which someone notices a bad migration or a dropped table.
  default_retention_rule {
    life_cycle {
      duration        = var.pg_weekly_retention
      data_store_type = "VaultStore"
    }
  }

  # Long term: corruption only visible against a much older reference, and audit
  # data whose value is its age. Lower priority is evaluated first, so a backup
  # that is both the first of its month and of its year is kept for the yearly
  # duration.
  retention_rule {
    name     = "yearly"
    priority = 10

    criteria {
      absolute_criteria = "FirstOfYear"
    }

    life_cycle {
      duration        = var.pg_yearly_retention
      data_store_type = "VaultStore"
    }
  }

  retention_rule {
    name     = "monthly"
    priority = 20

    criteria {
      absolute_criteria = "FirstOfMonth"
    }

    life_cycle {
      duration        = var.pg_monthly_retention
      data_store_type = "VaultStore"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "azurerm_data_protection_backup_instance_postgresql_flexible_server" "pg" {
  name             = "psql-product-a-prod"
  location         = azurerm_resource_group.prod.location
  vault_id         = azurerm_data_protection_backup_vault.prod.id
  server_id        = azurerm_postgresql_flexible_server.pg.id
  backup_policy_id = azurerm_data_protection_backup_policy_postgresql_flexible_server.pg.id

  depends_on = [time_sleep.rbac_propagation]

  lifecycle {
    # protection_state is computed and refreshed on every read, so this turns the
    # silent failure described above into a failed plan. An instance left in
    # ProtectionStopped by an undelete that was never resumed takes no backups and
    # produces no failed jobs, so nothing else -- not drift, not a job-failure
    # alert -- would ever mention it.
    postcondition {
      condition     = self.protection_state == "ProtectionConfigured"
      error_message = "psql-product-a-prod is not protected (protection_state is not ProtectionConfigured). If it is ProtectionStopped, run the resumeProtection call documented on time_sleep.rbac_propagation."
    }
  }
}

# --- Blob storage: operational backup ----------------------------------------------
# Retention is shared with the account's point-in-time-restore window (storage.tf).

resource "azurerm_data_protection_backup_policy_blob_storage" "blob" {
  name                                   = "bkpol-blob-product-a-prod"
  vault_id                               = azurerm_data_protection_backup_vault.prod.id
  operational_default_retention_duration = "P${var.blob_backup_retention_days}D"
}

resource "azurerm_data_protection_backup_instance_blob_storage" "blob" {
  name               = var.storage_account_name
  location           = azurerm_resource_group.prod.location
  vault_id           = azurerm_data_protection_backup_vault.prod.id
  storage_account_id = azurerm_storage_account.prod.id
  backup_policy_id   = azurerm_data_protection_backup_policy_blob_storage.blob.id

  depends_on = [time_sleep.rbac_propagation]
}
