# Office-hours-only cluster. A stopped AKS cluster deallocates its node pool VMs, and
# the node VMs are nearly the whole bill -- so running only weekday office hours
# cuts compute hours by more than half on the largest line item
# (../../docs/cost-analysis.md). Still billed while stopped: the OS disk, public
# IPs and Log Analytics data. Nothing is lost -- etcd is preserved, so workloads
# come back on start rather than being recreated.
#
# The committed defaults in variables.tf ARE the schedule that runs. A cost review
# found the live times overridden in a git-ignored tfvars, so a clean checkout plus
# `tofu apply` silently bought a longer day with a clean plan.
#
# An Azure Automation account does it: one runbook, two schedules, two job schedules.
# The runbook authenticates as the account's own managed identity, so there is no
# secret anywhere in this stack and every start/stop is attributable to a named
# principal in the activity log.

resource "azurerm_automation_account" "power" {
  name                = var.automation_account_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  # Basic is the tier that runs runbooks. The first 500 job-minutes per month are free
  # and these two jobs use roughly 250, so this is expected to cost nothing.
  sku_name = "Basic"

  # The identity the runbook acts as. Its rights are the custom role below and nothing
  # else -- read, start and stop this one cluster.
  identity {
    type = "SystemAssigned"
  }

  # Turns off the account's shared access keys, which exist to register DSC nodes and
  # agent-based Hybrid Runbook Workers and to authenticate webhooks. None of that is
  # used here, and a webhook URL is a bearer credential that could stop the cluster
  # with no Entra identity behind it. Schedule-triggered jobs authenticate through ARM
  # and are unaffected.
  local_authentication_enabled = false

  tags = var.tags
}

# Least privilege, deliberately custom. The obvious built-in, "Azure Kubernetes Service
# Contributor Role", carries `Microsoft.ContainerService/managedClusters/*` -- which
# includes listClusterAdminCredential, the one capability main.tf disables local accounts
# to make useless. Granting it to a headless identity would contradict that posture even
# though the call would fail. Three actions is all a power schedule needs.
#
# Defined at resource-group scope because Azure does not accept an individual resource as
# an assignable scope for a custom role; the assignment below is still cluster-scoped.
resource "azurerm_role_definition" "aks_power" {
  name        = "AKS Power Scheduler (${var.cluster_name})"
  scope       = azurerm_resource_group.rg.id
  description = "Read, start and stop the ${var.cluster_name} AKS cluster. For the Automation account that runs the off-hours power schedule. Created by OpenTofu (infra/org/aks-prod)."

  permissions {
    actions = [
      "Microsoft.ContainerService/managedClusters/read",
      "Microsoft.ContainerService/managedClusters/start/action",
      "Microsoft.ContainerService/managedClusters/stop/action",
    ]
    not_actions = []
  }

  assignable_scopes = [azurerm_resource_group.rg.id]
}

resource "azurerm_role_assignment" "automation_power" {
  scope              = azurerm_kubernetes_cluster.aks.id
  role_definition_id = azurerm_role_definition.aks_power.role_definition_resource_id
  principal_id       = azurerm_automation_account.power.identity[0].principal_id

  # Stated explicitly so the assignment does not fail on Entra replication lag while the
  # provider tries to resolve the freshly created identity's type -- same reason as rbac.tf.
  principal_type = "ServicePrincipal"
}

# One runbook, parameterised by action, rather than a near-identical pair.
#
# It calls the ARM REST API directly instead of using Az.Aks, which is not in the module
# set an Automation account ships with. Importing it (plus Az.Accounts) is a slow,
# version-fragile step that breaks on a module refresh long after anyone remembers it is
# load-bearing; two REST calls need no modules at all.
#
# Behaviour worth knowing: it is idempotent (already in the target state = success, so a
# manual `az aks start` before 06:00 does not fail the morning job), it refuses to act on
# a cluster that is mid-operation, and it waits for the cluster to actually settle -- so a
# start that fails is a Failed job in the history, not a silent surprise at 09:00.
resource "azurerm_automation_runbook" "aks_power" {
  name                    = "aks-power"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.power.name

  # "PowerShell" is the Windows PowerShell 5.1 runtime. Nothing here imports a module, so
  # there is no reason to move to 7.2 and take on its runtime-environment lifecycle.
  runbook_type = "PowerShell"
  description  = "Starts or stops ${var.cluster_name}. Driven by the aks-start / aks-stop schedules."

  # Job output is the record of why the cluster was up or down at a given time, so it is
  # kept; the verbose and progress streams add nothing to that.
  log_verbose  = false
  log_progress = false

  # Careful when editing: a heredoc is still a Terraform template, so a PowerShell
  # brace-delimited variable would be read as an interpolation and break the apply.
  # Hence "$($armBase)?api-version=..." below rather than the more usual PowerShell
  # "${armBase}?api-version=...". Plain $var and $(...) are left alone.
  content = <<-POWERSHELL
    <#
      Starts or stops an AKS cluster, as the Automation account's managed identity.
      Managed by OpenTofu in infra/org/aks-prod/automation.tf -- edit
      there, not in the portal, or the next apply reverts it.

      Job schedule parameter names arrive lowercased (Azure Automation normalizes them);
      PowerShell binds case-insensitively, so `action` and `clusterresourceid` land here.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Start', 'Stop')]
        [string] $Action,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $ClusterResourceId,

        # A stop settles in ~2-3 minutes, a start in ~5-10. 25 leaves headroom without
        # letting a wedged operation hold the job open (the sandbox limit is 3 hours).
        [int] $TimeoutMinutes = 25
    )

    $ErrorActionPreference = 'Stop'
    # Otherwise Invoke-RestMethod renders progress bars into the job output.
    $ProgressPreference = 'SilentlyContinue'
    # PowerShell 5.1 does not negotiate TLS 1.2 by default; without this every call
    # below fails on the handshake.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $apiVersion = '2024-09-01'
    $armBase = "https://management.azure.com$ClusterResourceId"
    $targetPowerState = if ($Action -eq 'Start') { 'Running' } else { 'Stopped' }

    if (-not $env:IDENTITY_ENDPOINT) {
        throw 'IDENTITY_ENDPOINT is not set: this runbook needs to run in an Automation account that has a managed identity.'
    }

    # Managed identity token from the endpoint the Automation sandbox injects. No secret,
    # and no Connect-AzAccount -- which would need Az.Accounts.
    $tokenResponse = Invoke-RestMethod -Method GET -Headers @{
        'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
        'Metadata'          = 'True'
    } -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://management.azure.com/&api-version=2019-08-01"

    $headers = @{ Authorization = "Bearer $($tokenResponse.access_token)" }

    function Get-ClusterState {
        $cluster = Invoke-RestMethod -Method GET -Headers $headers -Uri "$($armBase)?api-version=$apiVersion"
        [PSCustomObject]@{
            Power        = if ($cluster.properties.powerState.code) { $cluster.properties.powerState.code } else { 'Running' }
            Provisioning = $cluster.properties.provisioningState
        }
    }

    $state = Get-ClusterState
    Write-Output "$Action requested. Cluster is powerState=$($state.Power), provisioningState=$($state.Provisioning)."

    if ($state.Power -eq $targetPowerState) {
        Write-Output "Already $targetPowerState -- nothing to do."
        return
    }

    # A cluster mid-operation (Creating, Upgrading, Starting, Stopping) rejects start and
    # stop. Fail loudly rather than retry: the next scheduled run is the retry, and a job
    # marked Failed is the signal that something wants looking at.
    if ($state.Provisioning -ne 'Succeeded') {
        throw "provisioningState is '$($state.Provisioning)', not 'Succeeded' -- refusing to $Action a cluster that is mid-operation."
    }

    Write-Output "Issuing $($Action.ToLower())..."
    Invoke-RestMethod -Method POST -Headers $headers -Uri "$($armBase)/$($Action.ToLower())?api-version=$apiVersion" | Out-Null

    # The POST returns 202 and the work continues asynchronously. Poll the cluster itself
    # rather than the Azure-AsyncOperation header: power state is the condition that
    # actually matters, and reading it needs no permission beyond the GET already made.
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $settled = $false

    do {
        Start-Sleep -Seconds 30
        $state = Get-ClusterState
        Write-Output "  powerState=$($state.Power) provisioningState=$($state.Provisioning)"
        $settled = ($state.Power -eq $targetPowerState) -and ($state.Provisioning -eq 'Succeeded')
    } until ($settled -or (Get-Date) -ge $deadline)

    if (-not $settled) {
        throw "Timed out after $TimeoutMinutes minutes waiting for powerState=$targetPowerState (last seen powerState=$($state.Power), provisioningState=$($state.Provisioning))."
    }

    Write-Output "$Action complete: cluster is $targetPowerState."
  POWERSHELL

  tags = var.tags

  lifecycle {
    # job_schedule is Optional+Computed on this resource and the same association is
    # owned by the azurerm_automation_job_schedule resources below. Ignored so the two
    # representations of one link cannot fight over it.
    ignore_changes = [job_schedule]
  }
}

locals {
  # Azure rejects a schedule start_time less than five minutes in the future, so it
  # cannot be a literal: a date written into this file today is in the past by the next
  # apply. Anchored two days out instead, and then ignored (see the lifecycle blocks) --
  # only the first occurrence reads this value, every run after it comes from the weekly
  # recurrence.
  schedule_anchor      = timeadd(timestamp(), "48h")
  schedule_anchor_date = formatdate("YYYY-MM-DD", local.schedule_anchor)

  # start_time is an RFC3339 instant, and the UTC offset written into it is what fixes
  # the wall-clock time of the first run. `timezone` only carries that local time forward
  # across later DST changes -- it does not reinterpret the offset. So the offset has to
  # be the one actually in effect in var.schedule_timezone on the anchor date, or every
  # run for the life of the schedule lands an hour off.
  #
  # The EU rule applies: CEST (+02:00) from the last Sunday in March to the last
  # Sunday in October, CET (+01:00) otherwise, switching at 03:00 local -- before either
  # scheduled time, so comparing dates is enough. Last Sunday in March = 31 minus the
  # weekday index of the 31st. Derived rather than configured because a hand-set offset
  # is silently wrong for half of every year.
  weekday_number = { Sunday = 0, Monday = 1, Tuesday = 2, Wednesday = 3, Thursday = 4, Friday = 5, Saturday = 6 }
  anchor_year    = formatdate("YYYY", local.schedule_anchor)
  anchor_ymd     = tonumber(formatdate("YYYYMMDD", local.schedule_anchor))
  dst_begins_ymd = tonumber(format("%s03%02d", local.anchor_year, 31 - local.weekday_number[formatdate("EEEE", "${local.anchor_year}-03-31T00:00:00Z")]))
  dst_ends_ymd   = tonumber(format("%s10%02d", local.anchor_year, 31 - local.weekday_number[formatdate("EEEE", "${local.anchor_year}-10-31T00:00:00Z")]))
  schedule_offset = (
    local.anchor_ymd >= local.dst_begins_ymd && local.anchor_ymd < local.dst_ends_ymd
    ? "+02:00"
    : "+01:00"
  )
}

resource "azurerm_automation_schedule" "stop" {
  name                    = "aks-stop"
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.power.name
  description             = "Weekday evening shutdown of ${var.cluster_name}, ${var.cluster_stop_time} ${var.schedule_timezone}."

  frequency = "Week"
  interval  = 1
  week_days = var.power_schedule_days
  timezone  = var.schedule_timezone

  start_time = "${local.schedule_anchor_date}T${var.cluster_stop_time}:00${local.schedule_offset}"

  lifecycle {
    # Derived from timestamp(), so it changes on every plan while meaning nothing after
    # creation. Ignored to keep routine plans clean. To move the time of day, change
    # var.cluster_stop_time and taint or replace this schedule.
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_schedule" "start" {
  name                    = "aks-start"
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.power.name
  description             = "Weekday morning start of ${var.cluster_name}, ${var.cluster_start_time} ${var.schedule_timezone}."

  frequency = "Week"
  interval  = 1
  week_days = var.power_schedule_days
  timezone  = var.schedule_timezone

  start_time = "${local.schedule_anchor_date}T${var.cluster_start_time}:00${local.schedule_offset}"

  lifecycle {
    # See the note on the stop schedule.
    ignore_changes = [start_time]
  }
}

# Parameter keys MUST be lowercase. Azure Automation normalizes parameter names, and the
# provider compares what it sent against what came back -- a camelCase key here is a
# permanent diff that never converges.
resource "azurerm_automation_job_schedule" "stop" {
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.power.name
  runbook_name            = azurerm_automation_runbook.aks_power.name
  schedule_name           = azurerm_automation_schedule.stop.name

  parameters = {
    action            = "Stop"
    clusterresourceid = azurerm_kubernetes_cluster.aks.id
  }
}

resource "azurerm_automation_job_schedule" "start" {
  resource_group_name     = azurerm_resource_group.rg.name
  automation_account_name = azurerm_automation_account.power.name
  runbook_name            = azurerm_automation_runbook.aks_power.name
  schedule_name           = azurerm_automation_schedule.start.name

  parameters = {
    action            = "Start"
    clusterresourceid = azurerm_kubernetes_cluster.aks.id
  }
}
