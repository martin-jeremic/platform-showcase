# The API server writes an audit log natively; AKS discards it unless a diagnostic
# setting says otherwise. This is that setting, plus somewhere to put it.

resource "azurerm_log_analytics_workspace" "aks" {
  name                = var.log_analytics_workspace_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku               = "PerGB2018"
  retention_in_days = var.log_retention_days

  # Defaults to -1 (unlimited) if omitted. A cost circuit breaker, set well above
  # the observed baseline: hitting it stops ingestion for the rest of the UTC day,
  # which is a hole in the audit trail.
  daily_quota_gb = var.log_daily_quota_gb

  tags = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "aks_audit" {
  name                       = "aks-audit"
  target_resource_id         = azurerm_kubernetes_cluster.aks.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id

  # Resource-specific tables (AKSAuditAdmin, AKSControlPlane) instead of the legacy
  # AzureDiagnostics catch-all, which is one very wide shared table with a hard
  # column limit. Same cost.
  log_analytics_destination_type = "Dedicated"

  # kube-audit-admin: every MUTATING call (kube-audit minus get/list), plus
  # subresources like pods/exec and pods/portforward. The "who changed what"
  # record, in AKSAuditAdmin.
  #
  # kube-audit is the same stream INCLUDING reads, so enabling both pays twice for
  # every write. It is off; the cost is not seeing who READ a Secret. Related trap:
  # category_group = "audit" pulls in both -- enumerate instead.
  enabled_log {
    category = "kube-audit-admin"
  }

  # guard: the Entra authn/authz webhook's decisions -- token validation, group
  # resolution, denials. Lands in AKSControlPlane as free text with no User column,
  # so it explains WHY something was denied but cannot be joined to AKSAuditAdmin.
  enabled_log {
    category = "guard"
  }

  # No metrics. If added later, use `enabled_metric`; the older `metric` block is
  # deprecated for removal in azurerm v5.
}
