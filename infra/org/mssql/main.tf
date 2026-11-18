terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "org-mssql.tfstate"
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

# ADOPTED BY IMPORT from a hand-built server (../../docs/import-methodology.md).
# The import plan read "N to import, 0 to add, 0 to change, 0 to destroy" and the
# plan after it "No changes": that no-op is the proof the config matches reality.
#
# The RG, the server and the databases all carry prevent_destroy: they hold live
# production data with no copy in this repo, so any plan that would remove them is
# a mistake by definition. It also catches ForceNew changes (a rename, a collation
# change) that would otherwise plan as a silent destroy-and-create of a database.

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_mssql_server" "sql" {
  name                = var.server_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  version             = "12.0"

  # Password auth only; no Entra admin is configured on the live server.
  #
  # The password is WRITE-ONLY: Azure never returns it, so it imports as null and
  # any value in config reads as a change. Applying that change would RESET the
  # live admin password and break every application connection string on this
  # server, so it is held inert by ignore_changes below. The provider still demands
  # the argument, which is why the variable exists at all.
  administrator_login          = var.administrator_login
  administrator_login_password = var.administrator_login_password

  minimum_tls_version                  = "1.2"
  public_network_access_enabled        = true
  outbound_network_restriction_enabled = false

  lifecycle {
    prevent_destroy = true

    # The password is not managed here -- see the comment on the argument. Remove
    # this entry at go-live, in its own reviewed change, to rotate it deliberately.
    ignore_changes = [administrator_login_password]
  }

  tags = var.tags
}

# Tier, size and backup cadence are per database rather than hoisted scalars:
# one database's SKU moves independently of the others.
resource "azurerm_mssql_database" "db" {
  for_each = var.databases

  name      = each.key
  server_id = azurerm_mssql_server.sql.id

  sku_name             = each.value.sku_name
  max_size_gb          = each.value.max_size_gb
  storage_account_type = each.value.storage_account_type
  collation            = var.collation
  zone_redundant       = false

  short_term_retention_policy {
    retention_days           = each.value.retention_days
    backup_interval_in_hours = each.value.backup_interval_in_hours
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

# Not guarded: the allow-list is meant to be edited and a rule holds no data.
resource "azurerm_mssql_firewall_rule" "rules" {
  for_each = var.firewall_rules

  name             = each.key
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = each.value.start_ip_address
  end_ip_address   = each.value.end_ip_address
}

# prevent_destroy is invisible to anyone clicking Delete in the portal -- it only
# constrains OpenTofu. This is the Azure-side half of the guard, scoped to the
# resource group so it also covers databases added later. Added in the SECOND
# commit after the import (additive changes stay out of the no-op import plan).
#
# Needs Owner or User Access Administrator. It also blocks OpenTofu's own deletes,
# so an intentional teardown is two deliberate steps: remove the lock, lift
# prevent_destroy.
resource "azurerm_management_lock" "mssql" {
  name       = "mssql-no-delete"
  scope      = azurerm_resource_group.rg.id
  lock_level = "CanNotDelete"
  notes      = "Live application databases. Managed by infra/org/mssql."
}
