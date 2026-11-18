output "graph_client_id" {
  description = "Client ID of the app registration: the oauth2 client_id of the Graph /sendMail webhook in each cluster's observability overlay. Not a secret."
  value       = azuread_application.alerting.client_id
}

output "service_principal_object_id" {
  description = "Object ID of the app's SERVICE PRINCIPAL (Enterprise application), not of the app registration. Exchange's pointer and role assignment name it."
  value       = azuread_service_principal.alerting.object_id
}

output "graph_senders" {
  description = "Per destination: the mailbox it sends as. The Exchange scope limits Mail.Send to the set of these."
  value       = { for k, d in local.destinations : k => d.sender }
}

# The whole Exchange step as one line, so whoever holds the Exchange role gets
# every input without reading the state -- which also holds every Graph secret and
# trigger URL. -SenderMailbox is a PowerShell array literal.
output "exchange_sender_scope_command" {
  description = "Complete invocation of exchange/Set-AlertingSenderScope.ps1. Hand the script and this line to an Exchange administrator; they need neither tofu nor this state."
  value = join(" ", [
    "./Set-AlertingSenderScope.ps1",
    "-AppId '${azuread_application.alerting.client_id}'",
    "-ServicePrincipalObjectId '${azuread_service_principal.alerting.object_id}'",
    "-DisplayName '${replace(azuread_application.alerting.display_name, "'", "''")}'", # PowerShell: '' is a literal '
    "-SenderMailbox ${join(",", [for m in local.graph_senders : "'${replace(m, "'", "''")}'"])}",
  ])
}

output "graph_secret_end_dates" {
  description = "Per cluster: when Entra stops accepting the current Graph client secret."
  value       = { for k, p in azuread_application_password.graph : k => p.end_date }
}

output "teams_connection_id" {
  description = "The one object to authorise once in the portal (Edit API connection -> Authorize)."
  value       = azurerm_api_connection.teams.id
}

output "logic_apps" {
  description = "Per destination: the Logic App that posts its cards (its run history explains a failed post) and the caller ranges its trigger accepts (empty = anyone holding the URL)."
  value = {
    for k, w in azurerm_logic_app_workflow.teams : k => {
      name            = w.name
      allowed_callers = lookup(local.allowed_caller_cidrs, local.destinations[k].cluster, [])
    }
  }
}

output "key_vault_objects" {
  description = "Per destination: the vault object written for it, by the name the SecretProviderClass mounts."
  value       = { for k, s in azurerm_key_vault_secret.teams_webhook_url : k => s.name }
}
