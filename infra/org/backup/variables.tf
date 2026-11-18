variable "subscription_id" {
  description = "Azure subscription ID to deploy into (platform subscription)."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for the backup resource group and storage account. Same region as the cluster keeps egress free; the off-region copy comes from GRS replication, not from placing the account elsewhere."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Name of the dedicated resource group holding backups. Kept separate from rg-org-aks so a `tofu destroy` of the cluster stack can never reach the backups that protect it."
  type        = string
  default     = "rg-org-backup"
}

variable "storage_account_name" {
  description = "Name of the backup storage account. Must be globally unique across all of Azure: 3-24 lowercase alphanumeric characters — which is why there are no hyphens, exactly as with sttfstateexample."
  type        = string
  default     = "stbackuporg"

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 characters, lowercase letters and numbers only."
  }
}

variable "container_name" {
  description = "Blob container holding the mongodump output."
  type        = string
  default     = "mongo-backups"
}

variable "replication_type" {
  description = "Storage account replication. GRS, deliberately unlike ../../tfstate-bootstrap: its LRS is justified by state being re-creatable from Azure via import, and a Mongo dump is re-creatable from nothing. GRS keeps a copy in the paired region for cents at this volume."
  type        = string
  default     = "GRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "GZRS", "RAGRS", "RAGZRS"], var.replication_type)
    error_message = "replication_type must be one of LRS, ZRS, GRS, GZRS, RAGRS, RAGZRS."
  }
}

variable "soft_delete_days" {
  description = "Retention for soft-deleted blobs and containers. This is the undo window for an accidental deletion by someone with rights the backup job does not have."
  type        = number
  default     = 30

  validation {
    condition     = var.soft_delete_days >= 1 && var.soft_delete_days <= 365
    error_message = "soft_delete_days must be between 1 and 365."
  }
}

variable "tier_to_cool_days" {
  description = "Age in days at which a backup blob moves to the Cool tier. Cool storage is cheaper to keep and dearer to read, which matches a backup nobody expects to touch."
  type        = number
  default     = 30
}

variable "tier_to_cold_days" {
  description = "Age in days at which a backup blob moves to the Cold tier. Cheaper again, still online — unlike Archive, which is deliberately not used here."
  type        = number
  default     = 90
}

variable "retention_days" {
  description = "Age in days at which a backup blob is deleted. The backup job has no delete permission, so this policy is the only thing that prunes old dumps — set it to the real retention requirement, not a guess."
  type        = number
  default     = 365

  validation {
    condition     = var.retention_days > var.tier_to_cold_days
    error_message = "retention_days must be greater than tier_to_cold_days, otherwise blobs are deleted before they ever reach the Cold tier."
  }
}

variable "version_retention_days" {
  description = "Age in days at which a non-current blob version is deleted. Versions are created when a dump overwrites an existing blob name; without this they accumulate forever."
  type        = number
  default     = 90
}

variable "cluster_name" {
  description = "Name of the AKS cluster whose workloads write backups. Read (not created) here, to obtain the OIDC issuer URL that federation is anchored to."
  type        = string
  default     = "aks-org-prod"
}

variable "cluster_resource_group_name" {
  description = "Resource group holding the AKS cluster. Managed by ../aks-prod."
  type        = string
  default     = "rg-org-aks"
}

variable "backup_identity_name" {
  description = "Name of the user-assigned managed identity the backup job runs as. User-assigned rather than the kubelet identity on purpose — see identity-access.tf."
  type        = string
  default     = "id-org-mongo-backup"
}

variable "mongo_namespace" {
  description = "Kubernetes namespace the MongoDB backup job runs in. No default: federation is scoped to exactly one namespace/ServiceAccount pair, and a wrong guess here would silently federate the wrong workload."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.mongo_namespace)) && length(var.mongo_namespace) <= 63
    error_message = "mongo_namespace must be a valid DNS-1123 label: lowercase alphanumerics and '-', starting and ending with an alphanumeric, at most 63 characters."
  }
}

variable "mongo_backup_service_account" {
  description = "Kubernetes ServiceAccount the backup CronJob runs as. Must match the ServiceAccount defined in gitops/platform exactly — the subject string is compared verbatim during token exchange."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.mongo_backup_service_account)) && length(var.mongo_backup_service_account) <= 253
    error_message = "mongo_backup_service_account must be a valid DNS-1123 subdomain: lowercase alphanumerics and '-', starting and ending with an alphanumeric."
  }
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload    = "backup"
    environment = "prod"
    managed_by  = "opentofu"
  }
}
