resource "random_password" "pg_admin" {
  length  = 32
  special = false
}

resource "azurerm_postgresql_flexible_server" "pg" {
  name = "psql-product-a-prod"
  # Follows the resource group. Demo split this into var.dblocation because its
  # compute and database ended up in different regions; prod is single-region.
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name

  version    = "17"
  sku_name   = var.pg_sku
  storage_mb = var.pg_storage_mb

  # Co-located with the node pools (var.node_zones). Keep them in step: every token
  # operation and every application query crosses this hop, and a mismatch pays
  # cross-zone latency on all of it for no benefit.
  #
  # IMMUTABLE. Changing it replaces the server, which prevent_destroy blocks -- so
  # it is a dump/restore, not an apply.
  zone = var.pg_zone

  administrator_login    = var.pg_admin_login
  administrator_password = random_password.pg_admin.result

  # Both immutable at create, so they default to the prod-safe value rather than
  # being gated on var.ha. Geo-redundant backup cannot be turned on later.
  backup_retention_days        = var.pg_backup_retention_days
  geo_redundant_backup_enabled = var.pg_geo_redundant_backup

  public_network_access_enabled = true

  # Mixed mode: Entra tokens for humans and workload identity, password auth kept
  # for the application connection strings. Turning password auth off is a later
  # step, once every consumer is on Entra.
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = true
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  # SameZone HA: a hot standby in the SAME zone as the primary. It protects against
  # instance and node failure, NOT against losing the zone.
  #
  # ZoneRedundant IS NOT AVAILABLE HERE, and that was measured, not assumed:
  #   az postgres flexible-server list-skus -l <region>
  #   -> supportedFeatures: ZoneRedundantHa = Disabled,
  #      ZoneRedundantHaAndGeoBackup = Disabled
  #   -> every SKU, Burstable and General Purpose alike: supportedHaMode = [SameZone]
  #
  # So mode = "ZoneRedundant" would be rejected the moment ha = true is flipped --
  # a config that renders only under that flag, i.e. one that looks fine until the
  # exact moment it matters. Do not "restore" it without re-running that command.
  #
  # standby_availability_zone is omitted on purpose: under SameZone the standby
  # follows the primary, and naming a different zone contradicts the mode.
  dynamic "high_availability" {
    for_each = var.ha ? [1] : []
    content {
      mode = "SameZone"
    }
  }

  maintenance_window {
    day_of_week  = 0 # Sunday
    start_hour   = 3
    start_minute = 0
  }

  lifecycle {
    prevent_destroy = true

    # Fails the PLAN rather than the apply. Burstable SKUs cannot run HA in any
    # mode, and the error Azure returns does not say so.
    precondition {
      condition     = !(var.ha && startswith(var.pg_sku, "B_"))
      error_message = "ha = true requires a non-Burstable pg_sku (e.g. GP_Standard_D2ds_v5). Note this region offers SameZone HA only: HA here means instance redundancy inside one zone, not zone survival."
    }
  }

  tags = local.tags
}

# Optional Entra administrator. Off by default because it needs a real principal;
# set both variables in an untracked *.auto.tfvars to enable it.
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "admin" {
  count = var.pg_entra_admin_object_id == null ? 0 : 1

  server_name         = azurerm_postgresql_flexible_server.pg.name
  resource_group_name = azurerm_resource_group.prod.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = var.pg_entra_admin_object_id
  principal_name      = var.pg_entra_admin_principal_name
  principal_type      = var.pg_entra_admin_principal_type
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "aks_outbound" {
  name             = "allow-aks-outbound"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = azurerm_public_ip.aks_outbound.ip_address
  end_ip_address   = azurerm_public_ip.aks_outbound.ip_address
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "admin_clients" {
  for_each         = var.pg_admin_client_ips
  name             = "allow-${each.key}"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = each.value
  end_ip_address   = each.value
}

# Same allowlist as demo; see the note in ../aks-demo/postgres.tf.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = "PGCRYPTO,PG_TRGM,UNACCENT"
}

# --- Databases ------------------------------------------------------------------
# Every name below is a literal somewhere else (a JDBC URL in a chart, a connection
# string in Key Vault). Nothing validates the pairing: a mismatch makes the pods
# start, fail to connect, and report a driver error that never names the missing
# database. The audit database was once renamed upstream and the comment trail
# here exists so it is not renamed again without moving its consumers with it.

locals {
  databases = {
    # The identity provider's store. UTF8 is not cosmetic: it stores user
    # attributes and display names verbatim, and a non-UTF8 database corrupts them
    # silently.
    keycloak = "Every user, client, role and session of the identity provider."
    # Multi-tenant: a migrator issues CREATE SCHEMA per tenant inside it.
    product_a = "Every tenant schema and all business data."
    # Tamper-evident; the append-only trigger lives inside the database.
    product_a_audit_logs = "Audit data whose hash chain resets if the database is recreated."
  }
}

resource "azurerm_postgresql_flexible_server_database" "db" {
  for_each = local.databases

  name      = each.key
  server_id = azurerm_postgresql_flexible_server.pg.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = true
  }
}

# --- ROLES ARE NOT MANAGED HERE -----------------------------------------------------
# ARM exposes Flexible Server DATABASES but not ROLES: a role lives inside
# PostgreSQL, so creating one means connecting to the server and issuing SQL.
#
# The declarative option, the cyrilgdn/postgresql provider, is deliberately NOT
# used in this stack (the org stack does use it -- ../../org/postgres), for three
# reasons that point the same way:
#   1. It needs a network path from wherever `tofu` runs to the server: a firewall
#      entry for every operator and CI agent. The AKS egress IP is already trusted;
#      a laptop is not.
#   2. The role passwords would become inputs, i.e. land in state. They live only
#      in Key Vault, read by the charts over CSI.
#   3. It is a handful of statements, run once per server.
#
# Run ../../scripts/postgres/create-app-roles.sql from INSIDE the cluster after the
# first apply (README there). Two traps it handles:
#   - PostgreSQL 15+ no longer lets every role write to schema `public`; without
#     the GRANT the identity provider connects fine and then fails to create its
#     schema, which reads like a bug in the application.
#   - The audit writer role must come from the service's own migration script,
#     which installs the append-only trigger in the same pass. Creating the role
#     by hand gets the login without the guarantee -- the failure that looks like
#     success.

resource "azurerm_key_vault_secret" "pg_admin_password" {
  count = var.enable_key_vault_access ? 1 : 0

  provider     = azurerm.shared
  name         = "postgres--admin--password"
  value        = random_password.pg_admin.result
  key_vault_id = data.azurerm_key_vault.app[0].id
  content_type = "Administrator password of ${azurerm_postgresql_flexible_server.pg.name} (product-a/aks-prod)"
  tags         = local.tags
}
