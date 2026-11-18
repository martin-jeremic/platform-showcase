output "client_id" {
  description = "Client ID of the portal identity, for the chart's azure.clientId. Not the principal/object ID."
  value       = azurerm_user_assigned_identity.backstage.client_id
}

output "federated_subject" {
  description = "The exact ServiceAccount the federation is bound to."
  value       = azurerm_federated_identity_credential.backstage.subject
}
