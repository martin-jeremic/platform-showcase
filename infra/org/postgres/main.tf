resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# The shared PostgreSQL server for the organisation's services.
resource "azurerm_postgresql_flexible_server" "pg" {
  name                = var.server_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  version  = var.postgres_version
  sku_name = var.sku_name

  storage_mb        = var.storage_mb
  auto_grow_enabled = var.storage_auto_grow_enabled

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  # Password authentication only; Entra auth is a follow-up.
  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = false
  }

  public_network_access_enabled = true

  # No high_availability block and no pinned zone: Burstable cannot run HA, and the
  # server lands on any available zone.

  lifecycle {
    # Shared server holding several services' data. The source had no guard here;
    # every other data-holding stack in this folder does.
    prevent_destroy = true

    # Azure assigns a zone at creation; without this every plan shows it as drift.
    ignore_changes = [zone]
  }

  tags = var.tags
}

resource "azurerm_postgresql_flexible_server_database" "databases" {
  for_each = var.databases

  name      = each.key
  server_id = azurerm_postgresql_flexible_server.pg.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    # Applies to every instance: removing an entry from var.databases is blocked the
    # same way an outright destroy is.
    prevent_destroy = true
  }
}

# Deliberately NOT guarded: the allow-list is meant to be edited and a rule holds
# no data. Guarding it would mean lifting the guard every time someone's IP
# changes, which trains people to lift guards.
resource "azurerm_postgresql_flexible_server_firewall_rule" "rules" {
  for_each = var.firewall_rules

  name             = each.key
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = each.value.start_ip_address
  end_ip_address   = each.value.end_ip_address
}

# Azure refuses CREATE EXTENSION ("not allow-listed") unless the extension is named
# in azure.extensions. This resource owns the WHOLE list: append for new needs;
# values set by hand in the portal are reverted on apply. Dynamic parameter.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  count = length(var.allowed_extensions) > 0 ? 1 : 0

  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = join(",", var.allowed_extensions)
}

# STATIC parameter: a change needs a server restart to take effect, and nothing
# restarts the server automatically -- do it in the portal/CLI after the apply. The
# value was first set by hand and then adopted with a one-shot import block (see
# ../../docs/import-methodology.md, config-driven imports).
resource "azurerm_postgresql_flexible_server_configuration" "max_connections" {
  name      = "max_connections"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = tostring(var.max_connections)
}
