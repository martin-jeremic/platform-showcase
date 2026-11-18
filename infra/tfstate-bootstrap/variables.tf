variable "subscription_id" {
  description = "Subscription that holds the state account. Null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for the state resource group and storage account."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group dedicated to state. Never destroyed by workload stacks."
  type        = string
  default     = "rg-tfstate"
}

variable "storage_account_name" {
  description = "Globally unique name of the shared state account. Must match storage_account_name in every backend block."
  type        = string
  default     = "sttfstateexample"

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase alphanumeric characters."
  }
}

variable "container_name" {
  description = "Blob container holding every state file. Each stack is one blob (its backend key)."
  type        = string
  default     = "tfstate"
}

variable "replication_type" {
  description = "Storage replication. LRS is acceptable here because state can be rebuilt by import; the backup stack uses GRS because a dump cannot."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "GZRS", "RAGRS", "RAGZRS"], var.replication_type)
    error_message = "replication_type must be one of LRS, ZRS, GRS, GZRS, RAGRS, RAGZRS."
  }
}

variable "soft_delete_days" {
  description = "Retention for soft-deleted state blobs and containers: the undo window for a bad apply or a deleted blob."
  type        = number
  default     = 30
}
