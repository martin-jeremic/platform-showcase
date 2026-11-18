variable "subscription_id" {
  description = "Platform subscription. Null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "tenant_id" {
  description = "Entra tenant for the access groups. Pin it to stop an apply landing in the wrong directory."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Resource group of the cluster and its reserved IPs."
  type        = string
  default     = "rg-org-aks"
}

variable "cluster_name" {
  description = "Name of the AKS cluster."
  type        = string
  default     = "aks-org-prod"
}

variable "sku_tier" {
  description = "Control-plane tier. Free = no uptime SLA (acceptable single-node, non-HA); Standard = paid SLA."
  type        = string
  default     = "Free"
}

variable "kubernetes_version" {
  description = "Minor alias (\"1.37\") for the control plane and every pool, never a patch. Raise ONE minor per apply; `az aks get-upgrades` lists what is reachable. Set here, not in a git-ignored tfvars, so the version prod runs is in git."
  type        = string
  default     = "1.37"
  nullable    = false

  # A patch pin is REFUSED, not just discouraged. It freezes the cluster on that
  # patch, forces a code change for every patch release, and fights the patch
  # upgrade channel in main.tf, which moves the patch under a fixed alias -- under
  # a pin that shows as drift on every plan.
  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor alias such as \"1.37\", not a patch version like \"1.37.1\"."
  }
}

variable "node_vm_size" {
  description = "VM size of the system pool (4 vCPU / 32 GiB AMD). ForceNew on the cluster; rotated via temporary_name_for_rotation."
  type        = string
  default     = "Standard_E4as_v6"
}

variable "node_count" {
  description = "Nodes in the system pool. 1 = not HA; going to 2 is an online node_count change (../../docs/two-node-ha.md)."
  type        = number
  default     = 1
}

variable "node_os_disk_size_gb" {
  description = "OS disk size of the system pool."
  type        = number
  default     = 128
}

# --- Legacy worker pool (nodepools.tf) -------------------------------------------

variable "legacy_node_pool_enabled" {
  description = "Whether the legacy-app worker pool exists. false destroys the pool (stops paying for it) while keeping its declaration and label/taint contract in the repo."
  type        = bool
  default     = false
}

variable "legacy_node_vm_size" {
  description = "VM size of the legacy-app pool. ForceNew on the pool: a change is a rotation during which pinned pods do not schedule."
  type        = string
  default     = "Standard_D4as_v6"
}

variable "legacy_node_max_count" {
  description = "Autoscaler ceiling. The autoscaler scales on REQUESTS, not usage, so this is the blast radius of an over-declared request, not a demand forecast."
  type        = number
  default     = 3

  validation {
    condition     = var.legacy_node_max_count >= 1
    error_message = "legacy_node_max_count must be at least 1 (the pool's min_count)."
  }
}

# --- Access --------------------------------------------------------------------

variable "namespaces" {
  description = "Application namespaces. Each gets one Entra group here and one `edit` RoleBinding from platform/charts/rbac."
  type        = list(string)
  default     = ["access", "i18n", "ordering", "payments", "hr", "legacy-app"]

  validation {
    condition     = length(var.namespaces) == length(distinct(var.namespaces))
    error_message = "namespaces must not contain duplicates."
  }

  validation {
    condition     = alltrue([for n in var.namespaces : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", n)) && length(n) <= 63])
    error_message = "Each namespace must be a valid DNS-1123 label."
  }
}

# --- Audit log -----------------------------------------------------------------

variable "log_analytics_workspace_name" {
  description = "Workspace receiving the Kubernetes audit log."
  type        = string
  default     = "log-org-aks-prod"
}

variable "log_retention_days" {
  description = "Workspace retention. 90 leaves room to investigate something noticed late; 30 often does not."
  type        = number
  default     = 90

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "log_daily_quota_gb" {
  description = "Daily ingestion cap (cost circuit breaker). Keep well above the observed baseline; -1 disables it."
  type        = number
  default     = 5
}

# --- Power schedule (automation.tf) ----------------------------------------------

variable "automation_account_name" {
  description = "Automation account running the off-hours power schedule."
  type        = string
  default     = "aa-org-aks-prod"
}

variable "schedule_timezone" {
  description = "IANA time zone of the schedules, so 18:00 stays 18:00 local across DST."
  type        = string
  default     = "Europe/Berlin"
}

variable "cluster_stop_time" {
  description = "Local stop time, HH:MM. The committed default is the schedule production runs."
  type        = string
  default     = "18:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.cluster_stop_time))
    error_message = "cluster_stop_time must be HH:MM in 24-hour form."
  }
}

variable "cluster_start_time" {
  description = "Local start time, HH:MM. Allow 5-10 minutes for the cluster to become ready."
  type        = string
  default     = "06:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.cluster_start_time))
    error_message = "cluster_start_time must be HH:MM in 24-hour form."
  }
}

variable "power_schedule_days" {
  description = "Days both schedules run. Weekdays only, so a Friday stop lasts until Monday."
  type        = list(string)
  default     = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

  validation {
    condition     = length(var.power_schedule_days) > 0 && alltrue([for d in var.power_schedule_days : contains(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], d)])
    error_message = "power_schedule_days must be a non-empty list of capitalised English day names."
  }
}

# --- Registry and vault ------------------------------------------------------------

variable "acr_name" {
  description = "Registry the kubelet identity pulls from."
  type        = string
  default     = "orgacr"
}

variable "acr_resource_group_name" {
  description = "Resource group of the registry."
  type        = string
  default     = "rg-container-registry"
}

variable "key_vault_name" {
  description = "Vault the Key Vault CSI driver reads application secrets from."
  type        = string
  default     = "kv-org-prod"
}

variable "key_vault_resource_group_name" {
  description = "Resource group of the vault."
  type        = string
  default     = "rg-keyvaults"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload    = "aks"
    environment = "prod"
    managed_by  = "opentofu"
  }
}
