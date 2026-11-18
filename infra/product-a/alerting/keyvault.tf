# Every notification credential, written straight into each cluster's vault.
#
# Names are fixed by the consumer: the observability chart's SecretProviderClass
# mounts exactly <prefix>--graph-client-secret, <prefix>--teams-webhook-url and one
# <prefix>--<audience>-teams-webhook-url per audience, and the Azure provider fails
# the WHOLE mount (alertmanager-0 stuck in ContainerCreating) if any is missing. So
# apply BEFORE the overlay change that enables notifications or adds an audience.
#
# Rotation is a new version of the same object: the CSI driver re-reads the vault
# every rotation poll interval and rewrites the mounted file; Alertmanager reads
# both *_file values at use. No Secret to re-apply, no pod restart.
#
# The applier needs Key Vault Secrets Officer on every vault in var.clusters (the
# vaults use RBAC authorisation; an access policy is ignored on them).

resource "azurerm_key_vault_secret" "graph_client_secret" {
  for_each = var.clusters

  provider     = azurerm.shared
  name         = "${var.object_prefix}--graph-client-secret"
  value        = azuread_application_password.graph[each.key].value
  key_vault_id = data.azurerm_key_vault.cluster[each.key].id

  # The vault shows the secret as expired on the day Entra stops accepting it.
  expiration_date = azuread_application_password.graph[each.key].end_date
  content_type    = "Entra client secret, app ${var.app_display_name} (client id ${azuread_application.alerting.client_id})"

  tags = merge(local.tags, { cluster = each.key })
}

resource "azurerm_key_vault_secret" "teams_webhook_url" {
  for_each = local.destinations

  provider     = azurerm.shared
  name         = "${var.object_prefix}--${each.value.webhook_object}"
  value        = azurerm_logic_app_trigger_http_request.alertmanager[each.key].callback_url
  key_vault_id = each.value.key_vault_id

  content_type = "Logic App trigger URL (${azurerm_logic_app_workflow.teams[each.key].name}); the sig= parameter is the credential"

  tags = each.value.tags
}
