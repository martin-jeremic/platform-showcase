output "client_id" {
  description = "Client ID of the identity: AZURE_CLIENT_ID of the hub repo-server (platform/charts/argocd hub values). Not the principal/object ID."
  value       = azurerm_user_assigned_identity.argocd.client_id
}

output "principal_id" {
  description = "Object ID of the identity: the user that appears in Azure DevOps organisation settings."
  value       = azurerm_user_assigned_identity.argocd.principal_id
}

output "federated_subject" {
  description = "The exact ServiceAccount the federation is bound to."
  value       = azurerm_federated_identity_credential.argocd.subject
}
