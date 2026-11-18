output "cluster_id" {
  description = "Resource ID of the AKS cluster."
  value       = azurerm_kubernetes_cluster.aks.id
}

output "oidc_issuer_url" {
  description = "Cluster OIDC issuer; ../backup and ../identities/trivy federate against it."
  value       = azurerm_kubernetes_cluster.aks.oidc_issuer_url
}

output "ingress_public_ip" {
  description = "Reserved ingress address: the A record, and the address the ingress Service binds to."
  value       = azurerm_public_ip.ingress.ip_address
}

output "egress_public_ip" {
  description = "Declared egress address every pod leaves from; the address downstream allow-lists name."
  value       = azurerm_public_ip.egress.ip_address
}

output "kubelet_client_id" {
  description = "Client ID of the kubelet identity, for azureKeyVault.kubeletClientId in the app overlays. Not the object ID used for role assignments."
  value       = azurerm_kubernetes_cluster.aks.kubelet_identity[0].client_id
}

# kube_config_raw is deliberately NOT exported: with local accounts disabled it
# yields only an exec-plugin stub that still needs an interactive Entra sign-in.
# Exporting it would advertise a break-glass path that does not exist.

output "namespace_group_ids" {
  description = "namespace => Entra group object ID, for platform/charts/rbac values. Stable for the life of the group: a one-time copy, not a sync."
  value       = { for ns, group in azuread_group.ns : ns => group.object_id }
}

output "group_id_to_name" {
  description = "Entra group object ID => display name. AKSAuditAdmin records groups as object IDs; this is the lookup table audit queries decode them with."
  value = merge(
    { (azuread_group.admins.object_id) = azuread_group.admins.display_name },
    { (azuread_group.readers.object_id) = azuread_group.readers.display_name },
    { for group in azuread_group.ns : group.object_id => group.display_name },
  )
}

output "power_schedule" {
  description = "The off-hours schedule as applied. Confirm the next run times in the portal after the first apply."
  value = {
    stop     = var.cluster_stop_time
    start    = var.cluster_start_time
    days     = var.power_schedule_days
    timezone = var.schedule_timezone
    offset   = local.schedule_offset
  }
}

output "log_analytics_workspace_id" {
  description = "Workspace holding the Kubernetes audit log."
  value       = azurerm_log_analytics_workspace.aks.id
}
