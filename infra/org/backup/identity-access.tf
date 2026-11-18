# How the in-cluster backup job reaches this storage account.
#
# Azure Workload Identity, not the kubelet managed identity. ../aks-prod
# grants AcrPull and Key Vault Secrets User to the *kubelet* identity, which is fine for
# those: anything the kubelet can do, every pod on the node can do through IMDS, and a
# cluster-wide right to pull images is not a meaningful escalation. Write access to the
# only copy of the production database is a different proposition. Federating a single
# ServiceAccount keeps it to the one workload that needs it.
#
# This is the first consumer of the OIDC issuer and mutating webhook that
# ../aks-prod/main.tf turns on and documents as unused -- the "app-side
# change only" migration that comment anticipated. No change to the cluster stack is
# needed to land this.
#
# Order of operations: ../aks-prod must be applied before this stack, as
# the data source below reads the live cluster. Reading works while the cluster is
# stopped by its power schedule, so an evening or weekend apply is fine.

data "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  resource_group_name = var.cluster_resource_group_name
}

# The identity the backup CronJob acts as. User-assigned rather than system-assigned
# because it must exist -- and be federated, and hold its role -- before the workload
# that uses it, and must survive that workload being deleted and recreated.
resource "azurerm_user_assigned_identity" "mongo_backup" {
  name                = var.backup_identity_name
  resource_group_name = azurerm_resource_group.backup.name
  location            = azurerm_resource_group.backup.location

  tags = var.tags
}

# The trust anchor. The cluster's OIDC issuer signs a token for the named
# ServiceAccount; Entra exchanges it for a token for the identity above, but only when
# issuer, subject and audience all match exactly.
#
# `subject` is compared verbatim as a string -- there is no wildcard and no prefix
# match. A ServiceAccount renamed or moved to another namespace in
# gitops/platform silently stops authenticating, with an error on the pod side
# that names the subject it presented. That is the first thing to check.
#
# The audience is the fixed constant Entra requires for this flow; it is not a value to
# invent per workload.
resource "azurerm_federated_identity_credential" "mongo_backup" {
  name = "mongo-backup-${var.mongo_namespace}"

  # Replaces the deprecated parent_id + resource_group_name pair, both of which the
  # provider warns about and drops in the next major version. The identity's resource
  # ID already encodes its resource group, which is why the separate field went away.
  user_assigned_identity_id = azurerm_user_assigned_identity.mongo_backup.id

  issuer   = data.azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject  = "system:serviceaccount:${var.mongo_namespace}:${var.mongo_backup_service_account}"
  audience = ["api://AzureADTokenExchange"]
}

# Least privilege, deliberately custom -- the same reasoning, and the same shape, as the
# "AKS Power Scheduler" role in ../aks-prod/automation.tf.
#
# The obvious built-in, "Storage Blob Data Contributor", includes
# .../blobs/delete. Handing that to a pod means anyone who compromises the database
# container can also erase the backups of it, which is the exact scenario backups exist
# for. Dropping one data action removes that.
#
# What is left is enough to upload: `write` for Put Blob and Put Block List, `add` for
# Append Block, `read` so the job can verify what it wrote and so a restore can list and
# download. `write` does still allow overwriting an existing blob name -- that residual
# is covered by versioning in main.tf, not by this role.
#
# The cost of the restriction, stated plainly: the job cannot prune old dumps. The
# lifecycle policy in main.tf does that instead.
resource "azurerm_role_definition" "blob_no_delete" {
  name        = "Mongo Backup Writer (${var.storage_account_name})"
  scope       = azurerm_storage_account.backup.id
  description = "Read, write and append blobs, but not delete them. For the federated identity the MongoDB backup CronJob runs as. Created by OpenTofu (infra/org/backup)."

  permissions {
    actions = []

    data_actions = [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action",
    ]

    not_actions      = []
    not_data_actions = []
  }

  assignable_scopes = [azurerm_storage_account.backup.id]
}

# Scoped to the container, not the account, so adding a second container later for an
# unrelated workload does not silently widen this identity's reach.
resource "azurerm_role_assignment" "mongo_backup_writer" {
  principal_id       = azurerm_user_assigned_identity.mongo_backup.principal_id
  role_definition_id = azurerm_role_definition.blob_no_delete.role_definition_resource_id
  scope              = "${azurerm_storage_account.backup.id}/blobServices/default/containers/${azurerm_storage_container.mongo.name}"

  # The user-assigned MI may not have propagated to Entra yet on the first apply; skip
  # the AAD principal existence check to avoid an apply-time race.
  skip_service_principal_aad_check = true
}
