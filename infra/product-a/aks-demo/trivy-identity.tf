# The identity the Trivy scan jobs pull private images with, so they can scan them.
#
# Pods on this cluster pull with the kubelet identity (identity-access.tf) and carry
# no imagePullSecrets, so the Trivy Operator -- which normally copies a workload's
# pull Secret into its scan job -- has nothing to copy. The scan job pulls the image
# itself, not the kubelet: every private-image scan failed with UNAUTHORIZED.
#
# Azure Workload Identity, NOT the kubelet identity: federating that would hand the
# scan pods Key Vault Secrets User on the app vault just to pull images. This
# identity holds AcrPull on one registry and nothing else.
#
# Kept in the cluster's own stack (the org cluster has a separate stack, see
# ../../org/identities/trivy): the issuer is read straight off the cluster
# resource, so a rebuilt cluster's new issuer reaches the federation on the next
# apply.
#
# Cluster side (platform/charts/trivy): the ServiceAccount annotation
# azure.workload.identity/client-id = output trivy_identity_client_id, and the
# scan-pod label azure.workload.identity/use=true. The chart fails its render when
# the label is set without the client ID.

resource "azurerm_user_assigned_identity" "trivy" {
  name                = "id-product-a-demo-trivy-acr-pull"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  tags                = local.tags
}

# The trust anchor. `subject` is compared verbatim -- no wildcard, no prefix match.
# A moved namespace or a renamed operator ServiceAccount silently stops
# authenticating, and the scan jobs fail with UNAUTHORIZED again. Check this first.
resource "azurerm_federated_identity_credential" "trivy" {
  name                      = "${azurerm_kubernetes_cluster.aks.name}-${var.trivy_namespace}-${var.trivy_service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.trivy.id

  issuer   = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject  = "system:serviceaccount:${var.trivy_namespace}:${var.trivy_service_account}"
  audience = ["api://AzureADTokenExchange"]
}

resource "azurerm_role_assignment" "trivy_acr_pull" {
  provider             = azurerm.shared
  principal_id         = azurerm_user_assigned_identity.trivy.principal_id
  principal_type       = "ServicePrincipal"
  role_definition_name = "AcrPull"
  scope                = data.azurerm_container_registry.shared.id

  skip_service_principal_aad_check = true
}
