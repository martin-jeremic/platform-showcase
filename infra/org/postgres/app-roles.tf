# One application's database, login role and password, declared end to end, so
# nothing is typed into psql or the portal: the password is generated here, set on
# the role, and written straight into the vault the app's CSI mount reads.
#
# The worked example is the developer portal (Backstage) on the hub. It runs with
# pluginDivisionMode: schema -- one schema per plugin inside one database, created
# by the app itself -- so the role needs CREATE on its database and nothing
# server-wide: no CREATEDB, no CREATEROLE.
#
# ROTATION: `tofu apply -replace=random_password.app["backstage"]`. The role and the
# vault object change in the same apply; the CSI driver picks up the new value
# within its poll interval and Reloader restarts the pod. The password does live in
# this stack's state, like the administrator's -- state access is secret access.

locals {
  app_roles = {
    backstage = {
      database   = "backstage"
      privileges = ["CONNECT", "CREATE", "TEMPORARY"]
    }
  }
}

resource "random_password" "app" {
  for_each = local.app_roles

  length = 40
  # Letters and digits only: the value travels through a vault object, an
  # environment variable and a connection config, none of which should have to
  # care about quoting.
  special = false
}

resource "postgresql_role" "app" {
  for_each = local.app_roles

  name     = each.key
  login    = true
  password = random_password.app[each.key].result

  # Applied through the public endpoint: the applier's IP must be allow-listed.
  depends_on = [azurerm_postgresql_flexible_server_firewall_rule.rules]
}

resource "postgresql_grant" "app_database" {
  for_each = local.app_roles

  database    = azurerm_postgresql_flexible_server_database.databases[each.value.database].name
  role        = postgresql_role.app[each.key].name
  object_type = "database"
  privileges  = each.value.privileges
}

# The vault is owned by ../keyvaults; this stack owns only these objects in it.
data "azurerm_key_vault" "apps" {
  name                = var.app_key_vault_name
  resource_group_name = var.app_key_vault_resource_group_name
}

resource "azurerm_key_vault_secret" "app_password" {
  for_each = local.app_roles

  name         = "${each.key}--postgres-password"
  value        = random_password.app[each.key].result
  key_vault_id = data.azurerm_key_vault.apps.id
  content_type = "PostgreSQL password of role ${each.key} on ${var.server_name} (org/postgres)"
  tags         = var.tags
}
