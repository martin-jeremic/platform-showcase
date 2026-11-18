resource "random_password" "pg_admin" {
  length  = 32
  special = false
}

resource "azurerm_postgresql_flexible_server" "pg" {
  name                = "psql-product-a-demo"
  location            = var.dblocation
  resource_group_name = azurerm_resource_group.demo.name

  version = "17"
  # Burstable SKUs can be capacity-restricted for new subscriptions in some
  # regions. Fall back to a General Purpose SKU through var.pg_sku if provisioning
  # is denied.
  sku_name   = var.pg_sku
  storage_mb = 32768
  zone       = "1"

  administrator_login    = var.pg_admin_login
  administrator_password = random_password.pg_admin.result

  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true

  lifecycle {
    # Holds application data. Sizing changes (sku_name, storage_mb) update in
    # place; anything that forces replacement (zone, name, a MAJOR version bump,
    # which the provider implements as a replace) is blocked. The source relaxed
    # this for a major upgrade "temporarily" and it stayed relaxed; a major upgrade
    # is a dump/restore or an in-place `az postgres flexible-server upgrade`
    # followed by a state refresh, never a plan that destroys the server.
    prevent_destroy = true
  }

  tags = local.tags
}

# Trust the cluster's static egress IP (network.tf). Pinned on the AKS load
# balancer, so it is stable across stop/start; no lookup of an ephemeral IP needed.
resource "azurerm_postgresql_flexible_server_firewall_rule" "aks_outbound" {
  name             = "allow-aks-outbound"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = azurerm_public_ip.aks_outbound.ip_address
  end_ip_address   = azurerm_public_ip.aks_outbound.ip_address
}

# Operator access (pgAdmin, one-off migrations). Empty by default: no direct public
# access is opened unless an operator supplies an IP through an untracked
# *.auto.tfvars or -var.
resource "azurerm_postgresql_flexible_server_firewall_rule" "admin_clients" {
  for_each         = var.pg_admin_client_ips
  name             = "allow-${each.key}"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = each.value
  end_ip_address   = each.value
}

# --- Extension allowlist ---------------------------------------------------------
# Azure Flexible Server refuses CREATE EXTENSION ("not allow-listed") unless the
# extension is named in the azure.extensions server parameter. The application's
# baseline DDL creates exactly these three:
#   pgcrypto - gen_random_uuid() primary-key defaults across the whole schema
#   pg_trgm  - trigram lookup indexes (a tenant migration hard-fails without it)
#   unaccent - text normalisation in the same lookup path
# This resource owns the WHOLE value: extend the list, never set it by hand in the
# portal (the next apply reverts it). Dynamic parameter: no restart.
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.pg.id
  value     = "PGCRYPTO,PG_TRGM,UNACCENT"
}

# The application database. Also the multi-tenant database: a migrator creates one
# schema per tenant inside it, so its login needs CREATE on the database. Nothing in
# this config or the chart validates the name against the connection string held
# in Key Vault; a mismatch surfaces as a driver error that never names the
# missing database.
resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = "product_a"
  server_id = azurerm_postgresql_flexible_server.pg.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = true
  }
}

# Tamper-evident audit data. The append-only guarantee is a trigger inside this
# database; dropping and recreating it silently resets the hash chain.
resource "azurerm_postgresql_flexible_server_database" "audit" {
  name      = "product_a_audit_logs"
  server_id = azurerm_postgresql_flexible_server.pg.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  lifecycle {
    prevent_destroy = true
  }
}

# Roles are NOT managed here: ARM exposes databases but not roles. See the long
# note in ../aks-prod/postgres.tf and ../../scripts/postgres/create-app-roles.sql.

# The admin password goes straight into the environment's vault, not into an
# output. Operators and the role script read it from there; state still holds it,
# which is why state access is treated as secret access.
resource "azurerm_key_vault_secret" "pg_admin_password" {
  provider     = azurerm.shared
  name         = "postgres--admin--password"
  value        = random_password.pg_admin.result
  key_vault_id = data.azurerm_key_vault.app.id
  content_type = "Administrator password of ${azurerm_postgresql_flexible_server.pg.name} (product-a/aks-demo)"
  tags         = local.tags
}
