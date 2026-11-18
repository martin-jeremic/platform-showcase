# Azure-plane permission only. "Cluster User Role" grants
# listClusterUserCredential -- what `az aks get-credentials` calls -- and nothing
# inside the cluster. Without it a user cannot download a kubeconfig at all,
# whatever their Kubernetes rights: the usual first-day stumble. So every group a
# human signs in with needs it, namespace groups included.
#
# Do NOT give anyone "Cluster Admin Role": it exists to call
# listClusterAdminCredential, which fails outright with local accounts disabled.

locals {
  cluster_user_groups = merge(
    {
      admins  = azuread_group.admins.object_id
      readers = azuread_group.readers.object_id
    },
    { for ns, group in azuread_group.ns : "ns-${ns}" => group.object_id },
  )
}

resource "azurerm_role_assignment" "cluster_user" {
  for_each = local.cluster_user_groups

  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value

  # Stated so the assignment does not fail on Entra replication lag while the
  # provider resolves the principal's type.
  principal_type = "Group"
}
