# ---------------------------------------------------------------------------
# Diagnostic settings.
#
# Destination is the environment's own storage account, NOT Log Analytics.
# Workload observability runs in-cluster (Prometheus + Loki), so a workspace would
# be a second, paid-per-GB copy of the same story. What is genuinely missing
# without this is the CONTROL PLANE view -- API server and autoscaler logs live
# outside the cluster and are simply gone if nothing captures them. A blob archive
# is the cheap way to have them when an incident needs them. (The org cluster made
# the opposite trade, Log Analytics with a cost cap, because it queries the audit
# log; see ../../org/aks-prod/monitoring.tf.)
#
# Categories are a variable rather than discovered with
# azurerm_monitor_diagnostic_categories: a data source that depends on a
# not-yet-created resource makes for_each unknown at plan time and fails.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "aks" {
  name               = "diag-aks-product-a-prod"
  target_resource_id = azurerm_kubernetes_cluster.aks.id
  storage_account_id = azurerm_storage_account.prod.id

  # kube-audit-admin is the write-only subset of kube-audit. Full kube-audit is by
  # far the most expensive category; add it only for a specific investigation.
  dynamic "enabled_log" {
    for_each = toset(var.aks_diagnostic_log_categories)
    content {
      category = enabled_log.value
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "pg" {
  name               = "diag-psql-product-a-prod"
  target_resource_id = azurerm_postgresql_flexible_server.pg.id
  storage_account_id = azurerm_storage_account.prod.id

  dynamic "enabled_log" {
    for_each = toset(var.pg_diagnostic_log_categories)
    content {
      category = enabled_log.value
    }
  }
}
