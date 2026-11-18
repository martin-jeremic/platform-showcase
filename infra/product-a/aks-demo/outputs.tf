output "aks_get_credentials_command" {
  description = "Command to fetch a kubeconfig for the demo cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.demo.name} --name ${azurerm_kubernetes_cluster.aks.name}"
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster (federated identities anchor to it)."
  value       = azurerm_kubernetes_cluster.aks.oidc_issuer_url
}

# The CLIENT id, not the object id: the Key Vault CSI driver's
# userAssignedIdentityID takes this one. Both are GUIDs; swapping them fails
# silently. This is the hand-off to the chart values.
output "kubelet_identity_client_id" {
  description = "Client ID of the kubelet identity, for the Key Vault CSI SecretProviderClass."
  value       = azurerm_kubernetes_cluster.aks.kubelet_identity[0].client_id
}

output "trivy_identity_client_id" {
  description = "Client ID of the Trivy scan identity, for the ServiceAccount annotation azure.workload.identity/client-id."
  value       = azurerm_user_assigned_identity.trivy.client_id
}

output "pg_fqdn" {
  description = "PostgreSQL Flexible Server FQDN."
  value       = azurerm_postgresql_flexible_server.pg.fqdn
}

output "pg_admin_password_secret" {
  description = "Key Vault object holding the PostgreSQL admin password. Read it with `az keyvault secret show`; it is deliberately not an output."
  value       = "${var.key_vault_name}/${azurerm_key_vault_secret.pg_admin_password.name}"
}

output "ingress_public_ip" {
  description = "Static public IP for the ingress controller."
  value       = azurerm_public_ip.ingress.ip_address
}

output "aks_outbound_public_ip" {
  description = "Static egress IP; the address the PostgreSQL firewall trusts."
  value       = azurerm_public_ip.aks_outbound.ip_address
}
