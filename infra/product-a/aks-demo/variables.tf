variable "subscription_id" {
  description = "Subscription hosting the cluster. Null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "shared_subscription_id" {
  description = "Shared-services subscription holding the registry and the per-environment Key Vaults. Same Entra tenant as the cluster subscription."
  type        = string
  default     = "22222222-2222-2222-2222-222222222222"
}

variable "location" {
  description = "Azure region for all resources except the database."
  type        = string
  default     = "germanywestcentral"
}

variable "dblocation" {
  description = "Azure region for the database. Separate because Burstable capacity was unavailable in the cluster region when this environment was built."
  type        = string
  default     = "westeurope"
}

variable "shape" {
  description = "Cluster shape: \"A\" = four node pools (physical isolation), \"B\" = one system node (cheapest)."
  type        = string
  default     = "A"

  validation {
    condition     = contains(["A", "B"], var.shape)
    error_message = "shape must be \"A\" or \"B\"."
  }
}

variable "ephemeral_os" {
  description = "Use d-suffix SKUs with ephemeral OS disks (no managed OS-disk cost). false falls back to s-suffix SKUs with managed disks."
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "AKS minor version, as a minor alias. AKS picks the patch and the patch channel keeps it current. Raise one minor per apply."
  type        = string
  default     = "1.37"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor alias such as \"1.37\", not a patch version."
  }
}

variable "pg_sku" {
  description = "PostgreSQL Flexible Server SKU."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "pg_admin_login" {
  description = "PostgreSQL administrator login name."
  type        = string
  default     = "pgadmin"
}

# Key = firewall-rule label, value = one public IPv4. Keep empty in committed
# config; operators set their own IP in an untracked *.auto.tfvars.
variable "pg_admin_client_ips" {
  description = "Map of label => public IPv4 allowed to reach PostgreSQL directly."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for ip in values(var.pg_admin_client_ips) : can(cidrhost("${ip}/32", 0))])
    error_message = "Each value must be a single IPv4 address (no CIDR suffix)."
  }
}

variable "storage_account_name" {
  description = "Globally unique storage account name."
  type        = string
  default     = "stproductademo"
}

variable "blob_backup_retention_days" {
  description = "Operational blob backup retention, shared with the account's point-in-time-restore window (soft delete is this + 1)."
  type        = number
  default     = 7
}

variable "acr_name" {
  description = "Shared container registry the kubelet identity pulls from."
  type        = string
  default     = "productacr"
}

variable "acr_resource_group_name" {
  description = "Resource group of the shared registry."
  type        = string
  default     = "rg-container-registry"
}

variable "key_vault_name" {
  description = "Per-environment Key Vault the kubelet identity reads and the PG admin password is written to."
  type        = string
  default     = "kv-product-a-demo"
}

variable "key_vault_resource_group_name" {
  description = "Resource group of the per-environment Key Vaults."
  type        = string
  default     = "rg-keyvaults"
}

variable "trivy_namespace" {
  description = "Namespace the Trivy operator runs in. Part of the federated subject, compared verbatim."
  type        = string
  default     = "trivy"
}

variable "trivy_service_account" {
  description = "ServiceAccount the scan jobs run as (the operator's own). Part of the federated subject, compared verbatim."
  type        = string
  default     = "trivy-operator"
}

# --- Off-hours power schedule (automation.tf) ----------------------------------

variable "enable_off_hours_shutdown" {
  description = "Create the Automation account, runbook and weekday start/stop schedules. Off by default: the demo cluster is kept stopped and started by hand."
  type        = bool
  default     = false
}

variable "schedule_timezone" {
  description = "IANA time zone the schedules run in. The UTC offset of the first run is derived for this zone's EU DST rule (automation.tf)."
  type        = string
  default     = "Europe/Berlin"
}

variable "cluster_start_time" {
  description = "Local start time, HH:MM."
  type        = string
  default     = "07:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.cluster_start_time))
    error_message = "cluster_start_time must be HH:MM in 24-hour form."
  }
}

variable "cluster_stop_time" {
  description = "Local stop time, HH:MM."
  type        = string
  default     = "18:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.cluster_stop_time))
    error_message = "cluster_stop_time must be HH:MM in 24-hour form."
  }
}
