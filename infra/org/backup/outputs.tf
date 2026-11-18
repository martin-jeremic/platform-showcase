output "resource_group_name" {
  description = "Name of the created resource group."
  value       = azurerm_resource_group.backup.name
}

output "storage_account_name" {
  description = "Name of the backup storage account. Shared access keys are disabled on it, so every `az storage ...` command against it needs `--auth-mode login`."
  value       = azurerm_storage_account.backup.name
}

output "container_name" {
  description = "Blob container the mongodump output is written to."
  value       = azurerm_storage_container.mongo.name
}

output "backup_identity_client_id" {
  description = "Client ID of the backup managed identity. This is the value that goes into the ServiceAccount's azure.workload.identity/client-id annotation in gitops/platform. Not the same as the principal/object ID used for role assignments."
  value       = azurerm_user_assigned_identity.mongo_backup.client_id
}

output "backup_identity_principal_id" {
  description = "Object (principal) ID of the backup managed identity — the principal that appears in the role assignment and in storage diagnostic logs."
  value       = azurerm_user_assigned_identity.mongo_backup.principal_id
}

output "federated_subject" {
  description = "The exact ServiceAccount subject federation is bound to. The namespace and ServiceAccount in gitops/platform must match this string verbatim; token exchange fails otherwise."
  value       = azurerm_federated_identity_credential.mongo_backup.subject
}

output "retention" {
  description = "The lifecycle policy as applied. The backup job cannot delete blobs, so this is the only thing pruning old dumps."
  value = {
    tier_to_cool_days     = var.tier_to_cool_days
    tier_to_cold_days     = var.tier_to_cold_days
    delete_after_days     = var.retention_days
    version_delete_after  = var.version_retention_days
    soft_delete_undo_days = var.soft_delete_days
    replication           = var.replication_type
  }
}
