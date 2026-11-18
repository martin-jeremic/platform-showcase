# ---------------------------------------------------------------------------
# Off-hours cost control: stop the whole AKS cluster outside working hours.
#
# Autoscaling (aks.tf) drains idle USER pools to zero, but AKS always keeps >= 1
# system node while the cluster runs. Stopping the cluster deallocates every node,
# which is the only way to get compute cost to roughly zero.
#
# Switched by var.enable_off_hours_shutdown. The source of this stack turned the
# schedule off by commenting out the two job-schedule bindings, because
# azurerm_automation_schedule has no enabled flag. A `count` switch keeps every
# address stable, removes everything cleanly when off, and needs no edit to bring
# it back. The demo cluster is normally kept stopped and started by hand, so the
# committed default is off.
#
# The org cluster runs the more robust variant of the runbook (idempotent, waits for
# the power state to settle, refuses to act mid-operation):
# ../../org/aks-prod/automation.tf.
# ---------------------------------------------------------------------------

locals {
  automation_count = var.enable_off_hours_shutdown ? 1 : 0
}

resource "azurerm_automation_account" "demo" {
  count = local.automation_count

  name                = "aa-product-a-demo"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  sku_name            = "Basic"

  # No shared keys: webhooks are bearer credentials that could stop the cluster
  # with no Entra identity behind them. Schedule-triggered jobs are unaffected.
  local_authentication_enabled = false

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# Least privilege. The source granted Contributor on the cluster, which includes
# listClusterAdminCredential. Three actions are all a power schedule needs.
# Defined at resource-group scope because a single resource is not accepted as an
# assignable scope for a custom role; the assignment itself is cluster-scoped.
resource "azurerm_role_definition" "aks_power" {
  count = local.automation_count

  name        = "AKS Power Scheduler (aks-product-a-demo)"
  scope       = azurerm_resource_group.demo.id
  description = "Read, start and stop one AKS cluster. For the off-hours Automation account."

  permissions {
    actions = [
      "Microsoft.ContainerService/managedClusters/read",
      "Microsoft.ContainerService/managedClusters/start/action",
      "Microsoft.ContainerService/managedClusters/stop/action",
    ]
    not_actions = []
  }

  assignable_scopes = [azurerm_resource_group.demo.id]
}

resource "azurerm_role_assignment" "automation_power" {
  count = local.automation_count

  scope              = azurerm_kubernetes_cluster.aks.id
  role_definition_id = azurerm_role_definition.aks_power[0].role_definition_resource_id
  principal_id       = azurerm_automation_account.demo[0].identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

# The first run must be in the future at create time (Azure rejects past start
# times). time_static records the first apply and never moves, so the derived
# anchor is stable in state and re-applies do not drift.
resource "time_static" "schedule_anchor" {
  count = local.automation_count
}

locals {
  schedule_week_days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

  # coalesce keeps the expression evaluable when the automation is counted out:
  # one() returns null on an empty list, and timeadd(null, ...) errors even though
  # nothing consumes the result.
  schedule_anchor = timeadd(coalesce(one(time_static.schedule_anchor[*].rfc3339), "2000-01-01T00:00:00Z"), "24h")
  schedule_date   = formatdate("YYYY-MM-DD", local.schedule_anchor)

  # The UTC offset written into start_time fixes the wall-clock time of the FIRST
  # run; `timezone` only carries that local time across later DST changes. So the
  # offset must be the one in effect on the anchor date, or every run for the life
  # of the schedule lands an hour off. The source hard-coded +02:00 (summer time),
  # which is wrong for half of every year.
  #
  # EU rule: summer time from the last Sunday in March to the last Sunday in
  # October, switching at a local hour before either scheduled time, so comparing
  # dates is enough. Last Sunday of a month with 31 days = 31 minus the weekday
  # index of the 31st.
  weekday_number  = { Sunday = 0, Monday = 1, Tuesday = 2, Wednesday = 3, Thursday = 4, Friday = 5, Saturday = 6 }
  anchor_year     = formatdate("YYYY", local.schedule_anchor)
  anchor_ymd      = tonumber(formatdate("YYYYMMDD", local.schedule_anchor))
  dst_begins_ymd  = tonumber(format("%s03%02d", local.anchor_year, 31 - local.weekday_number[formatdate("EEEE", "${local.anchor_year}-03-31T00:00:00Z")]))
  dst_ends_ymd    = tonumber(format("%s10%02d", local.anchor_year, 31 - local.weekday_number[formatdate("EEEE", "${local.anchor_year}-10-31T00:00:00Z")]))
  schedule_offset = local.anchor_ymd >= local.dst_begins_ymd && local.anchor_ymd < local.dst_ends_ymd ? "+02:00" : "+01:00"
}

resource "azurerm_automation_runbook" "power" {
  count = local.automation_count

  name                    = "aks-power"
  location                = azurerm_resource_group.demo.location
  resource_group_name     = azurerm_resource_group.demo.name
  automation_account_name = azurerm_automation_account.demo[0].name
  runbook_type            = "PowerShell"
  log_progress            = false
  log_verbose             = false
  description             = "Starts or stops aks-product-a-demo. Driven by the aks-start / aks-stop schedules."

  # A heredoc is still a template: a PowerShell "${var}" would be read as an
  # interpolation, so only plain $var and $(...) are used below.
  content = <<-POWERSHELL
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Start', 'Stop')][string] $Action,
        [Parameter(Mandatory = $true)][string] $ClusterResourceId
    )
    $ErrorActionPreference = 'Stop'
    Connect-AzAccount -Identity | Out-Null
    $r = Invoke-AzRestMethod -Method POST -Path "$ClusterResourceId/$($Action.ToLower())?api-version=2024-09-01"
    Write-Output "$Action requested. HTTP status: $($r.StatusCode)"
    if ($r.StatusCode -ge 400) { throw "$Action failed: $($r.Content)" }
  POWERSHELL

  tags = local.tags

  lifecycle {
    # Owned by the azurerm_automation_job_schedule resources below.
    ignore_changes = [job_schedule]
  }
}

resource "azurerm_automation_schedule" "power" {
  for_each = var.enable_off_hours_shutdown ? { start = var.cluster_start_time, stop = var.cluster_stop_time } : {}

  name                    = "aks-${each.key}"
  resource_group_name     = azurerm_resource_group.demo.name
  automation_account_name = azurerm_automation_account.demo[0].name
  frequency               = "Week"
  interval                = 1
  timezone                = var.schedule_timezone
  week_days               = local.schedule_week_days
  start_time              = "${local.schedule_date}T${each.value}:00${local.schedule_offset}"
  description             = "Weekday ${each.key} of aks-product-a-demo at ${each.value} ${var.schedule_timezone}."

  lifecycle {
    # Azure normalises start_time to UTC, which would otherwise read as perpetual
    # drift. It is only the first-run anchor; the recurrence is unaffected. To move
    # the time of day, change the variable and replace the schedule.
    ignore_changes = [start_time]
  }
}

# Parameter keys MUST be lowercase: Azure Automation normalises them, and the
# provider compares what it sent with what came back, so a camelCase key is a
# permanent diff.
resource "azurerm_automation_job_schedule" "power" {
  for_each = azurerm_automation_schedule.power

  resource_group_name     = azurerm_resource_group.demo.name
  automation_account_name = azurerm_automation_account.demo[0].name
  runbook_name            = azurerm_automation_runbook.power[0].name
  schedule_name           = each.value.name

  parameters = {
    action            = title(each.key)
    clusterresourceid = azurerm_kubernetes_cluster.aks.id
  }
}
