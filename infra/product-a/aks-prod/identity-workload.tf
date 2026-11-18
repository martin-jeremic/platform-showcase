# =============================================================================
# Workload identity for the observability stack
# =============================================================================
# Loki and Tempo write everything to blob and authenticate with WORKLOAD IDENTITY:
# the pod trades its projected ServiceAccount token for an Azure token. No account
# key in values, in a Secret, or in state.
#
# Deliberately NOT the kubelet-identity shortcut used for the Key Vault CSI mounts
# (identity-access.tf, a known gap). Those charts can use the CSI driver's
# VM-managed-identity mode; Loki and Tempo call the Azure SDK directly with a
# federated token and have no such escape hatch. Doing it properly here costs about
# forty lines.
#
# It is also the worked example for closing that gap: the same four objects per
# workload -- identity, federated credential, scoped role assignment, client_id
# into the chart overlay -- with "Key Vault Secrets User" on the vault instead of
# "Storage Blob Data Contributor" on a container.
#
# ---------------------------------------------------------------------------
# THE THREE WAYS THIS FAILS SILENTLY
# ---------------------------------------------------------------------------
#   1. WRONG SUBJECT. The federated credential's subject must equal the pod's
#      actual ServiceAccount, system:serviceaccount:<namespace>:<sa-name>. Get it
#      from the running pod, never from a chart's release name -- see the Loki
#      credential below, which is exactly where this went wrong.
#   2. client_id vs principal_id. The ServiceAccount annotation takes the CLIENT
#      id; the role assignment takes the PRINCIPAL (object) id. Both are GUIDs, and
#      swapping them gives "application not found" or a silent 403, never a type
#      error.
#   3. MISSING POD LABEL. The pod needs azure.workload.identity/use: "true" or the
#      webhook never injects the token volume. Verify with
#      `kubectl get pod loki-0 -o jsonpath='{.metadata.labels}'`.
#
# All three present as an auth failure that looks identical to a missing role
# assignment.

resource "azurerm_user_assigned_identity" "loki" {
  name                = "id-product-a-loki"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "loki" {
  name = "loki-observability"

  # user_assigned_identity_id, not parent_id + resource_group_name: azurerm 4.x
  # deprecates both, and the resource group is derived from the identity's own id.
  user_assigned_identity_id = azurerm_user_assigned_identity.loki.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = azurerm_kubernetes_cluster.aks.oidc_issuer_url

  # `loki`, NOT the release-prefixed name an overlay comment asserted. The chart
  # pins fullnameOverride: loki, so the ServiceAccount is `loki`, and that is what
  # the projected token's `sub` claim carries. Verified against the running pod,
  # not derived:
  #   kubectl -n observability get pod loki-0 -o jsonpath='{.spec.serviceAccountName}'
  #
  # Entra rejects a subject mismatch with the same error class as an unknown
  # application, so it reads as "the identity is wrong" rather than "the name is
  # wrong". Re-check if the chart's fullnameOverride ever changes.
  subject = "system:serviceaccount:observability:loki"
}

resource "azurerm_user_assigned_identity" "tempo" {
  name                = "id-product-a-tempo"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "tempo" {
  name                      = "tempo-observability"
  user_assigned_identity_id = azurerm_user_assigned_identity.tempo.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.aks.oidc_issuer_url

  # Confirmed against the running pod: Tempo's ServiceAccount DOES carry the
  # release prefix. Unlike Loki -- which is precisely why neither is assumed.
  subject = "system:serviceaccount:observability:observability-tempo"
}

# --- Role assignments ------------------------------------------------------------
# Scoped PER CONTAINER, not to the storage account. The account also holds the
# PostgreSQL backups and the diagnostic archives, kube-audit-admin included.
# Storage Blob Data Contributor at account scope would give a log-shipping daemon
# read/write over the audit trail that is supposed to observe it, and over the
# database backups. Three assignments instead of two is a cheap price.
#
# principal_id, NOT client_id (see the header). The scope uses the container's
# `.id`, which azurerm 4.x returns in ARM form (the separate resource_manager_id
# attribute is deprecated).

resource "azurerm_role_assignment" "loki_chunks" {
  principal_id         = azurerm_user_assigned_identity.loki.principal_id
  role_definition_name = "Storage Blob Data Contributor"
  scope                = azurerm_storage_container.loki_chunks.id

  skip_service_principal_aad_check = true
}

# Loki needs BOTH containers. Only ruler storage failed at startup because it
# initialises first -- granting chunks alone would move the crash, not fix it.
resource "azurerm_role_assignment" "loki_ruler" {
  principal_id         = azurerm_user_assigned_identity.loki.principal_id
  role_definition_name = "Storage Blob Data Contributor"
  scope                = azurerm_storage_container.loki_ruler.id

  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "tempo_traces" {
  principal_id         = azurerm_user_assigned_identity.tempo.principal_id
  role_definition_name = "Storage Blob Data Contributor"
  scope                = azurerm_storage_container.tempo_traces.id

  skip_service_principal_aad_check = true
}

# ── Alertmanager: reads its two notification credentials from Key Vault ─────────
# The alerting stack (../alerting) writes alertmanager--graph-client-secret and
# alertmanager--teams-webhook-url; the observability chart mounts them as files through CSI.
# Scoped to the two SECRETS, not the vault: "Key Vault Secrets User" at vault scope would let
# the notification pod read every application secret, which is the exact problem the
# kubelet identity still has (README, KNOWN-GAPS).
locals {
  alertmanager_secrets = toset(["alertmanager--graph-client-secret", "alertmanager--teams-webhook-url"])
}

resource "azurerm_user_assigned_identity" "alertmanager" {
  name                = "id-product-a-alertmanager"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "alertmanager" {
  name                      = "observability-alertmanager"
  user_assigned_identity_id = azurerm_user_assigned_identity.alertmanager.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  # <kubePromStack.fullnameOverride>-alertmanager, as rendered by platform/charts/observability.
  # Read it from the running pod before trusting this string (failure mode 1 above).
  subject = "system:serviceaccount:observability:kube-prom-stack-kube-prome-alertmanager"
}

resource "azurerm_role_assignment" "alertmanager_secrets" {
  for_each = var.enable_key_vault_access ? local.alertmanager_secrets : toset([])

  provider             = azurerm.shared
  principal_id         = azurerm_user_assigned_identity.alertmanager.principal_id
  role_definition_name = "Key Vault Secrets User"
  scope                = "${data.azurerm_key_vault.app[0].id}/secrets/${each.key}"

  # A new identity may not have replicated in Entra on the first apply.
  skip_service_principal_aad_check = true
}
