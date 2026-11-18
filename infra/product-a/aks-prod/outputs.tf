output "aks_get_credentials_command" {
  description = "Command to fetch a kubeconfig for the prod cluster."
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.prod.name} --name ${azurerm_kubernetes_cluster.aks.name}"
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster, needed to federate workload identities."
  value       = azurerm_kubernetes_cluster.aks.oidc_issuer_url
}

output "kubelet_identity_client_id" {
  description = "Client ID of the kubelet identity, for the Key Vault CSI SecretProviderClass."
  value       = azurerm_kubernetes_cluster.aks.kubelet_identity[0].client_id
}

output "observability_uami_client_ids" {
  description = <<-EOT
    Client IDs of the observability workload identities, for the
    azure.workload.identity/client-id ServiceAccount annotations in the prod
    observability overlay (gitops/platform). CLIENT id, not principal id: both are
    GUIDs, the annotation silently accepts either, and only one works.
  EOT
  value = {
    loki         = azurerm_user_assigned_identity.loki.client_id
    tempo        = azurerm_user_assigned_identity.tempo.client_id
    alertmanager = azurerm_user_assigned_identity.alertmanager.client_id
  }
}

# Exported because anything that peers into this VNet or adds a Private Endpoint
# later needs these and should not have to look them up by name.
output "vnet" {
  description = "VNet and subnet IDs, and the address space to check for overlap before peering."
  value = {
    id                 = azurerm_virtual_network.prod.id
    address_space      = azurerm_virtual_network.prod.address_space
    subnet_nodes       = azurerm_subnet.nodes.id
    subnet_privatelink = azurerm_subnet.privatelink.id
  }
}

output "pg_fqdn" {
  description = "PostgreSQL Flexible Server FQDN."
  value       = azurerm_postgresql_flexible_server.pg.fqdn
}

output "ingress_public_ip" {
  description = "Static IP for the ingress controller; the A records point here."
  value       = azurerm_public_ip.ingress.ip_address
}

output "aks_outbound_public_ip" {
  description = "Static egress IP; trusted by the PostgreSQL firewall and the alerting Logic App."
  value       = azurerm_public_ip.aks_outbound.ip_address
}

output "pg_backup_anchor" {
  description = "Derived first run of the weekly vaulted PostgreSQL backup."
  value       = local.pg_backup_anchor
}

# The chart generates the initial admin password into a Secret. It is read with
# kubectl rather than exported here on purpose: an output would write the prod
# admin password into state.
output "argocd_admin_password_command" {
  description = "Command to read the generated Argo CD admin password."
  value       = "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "argocd_port_forward_command" {
  description = "Command to reach the Argo CD UI before the wave-5 route exists."
  value       = "kubectl -n ${var.argocd_namespace} port-forward svc/${var.argocd_release_name}-server 8080:80"
}
