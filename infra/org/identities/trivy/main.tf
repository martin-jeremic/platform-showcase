terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "org-identity-trivy.tfstate"
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

# How the Trivy scan jobs on aks-org-prod pull private images to scan them.
#
# Pods there pull with the KUBELET identity (../../aks-prod/identity-access.tf) and
# carry no imagePullSecrets, so the Trivy Operator -- which normally copies a
# workload's pull Secret into its scan job -- has nothing to copy. The scan job
# pulls the image itself, not the kubelet, so without this every private-image
# scan fails with UNAUTHORIZED.
#
# Workload identity and NOT the kubelet identity: federating the kubelet identity
# would hand the scan pods everything it holds -- Key Vault Secrets User on the prod
# vault included -- just to pull images. This identity holds AcrPull on one
# registry and nothing else.
#
# Order: ../../aks-prod first; the data source reads the live cluster. Reading works
# while the power schedule has the cluster stopped.

resource "azurerm_resource_group" "trivy" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# User-assigned rather than system-assigned: it must exist, federated and holding
# its role, before the operator first starts a scan job.
resource "azurerm_user_assigned_identity" "trivy" {
  name                = var.identity_name
  resource_group_name = azurerm_resource_group.trivy.name
  location            = azurerm_resource_group.trivy.location
  tags                = var.tags
}

data "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  resource_group_name = var.cluster_resource_group_name
}

# `subject` is compared verbatim. A renamed operator ServiceAccount
# (trivy-operator.fullnameOverride) or a moved namespace silently stops
# authenticating, and the scan jobs fail with UNAUTHORIZED. Check this first.
resource "azurerm_federated_identity_credential" "trivy" {
  name                      = "${var.cluster_name}-${var.trivy_namespace}-${var.trivy_service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.trivy.id

  issuer   = data.azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject  = "system:serviceaccount:${var.trivy_namespace}:${var.trivy_service_account}"
  audience = ["api://AzureADTokenExchange"]
}

# Owned here, on the consumer side, like the kubelet identity's AcrPull.
data "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name
}

resource "azurerm_role_assignment" "acr_pull" {
  principal_id         = azurerm_user_assigned_identity.trivy.principal_id
  principal_type       = "ServicePrincipal"
  role_definition_name = "AcrPull"
  scope                = data.azurerm_container_registry.acr.id

  skip_service_principal_aad_check = true
}

output "client_id" {
  description = "Client ID for trivy-operator.serviceAccount.annotations.\"azure.workload.identity/client-id\" (platform/charts/trivy). Not the principal ID."
  value       = azurerm_user_assigned_identity.trivy.client_id
}

output "federated_subject" {
  description = "The exact ServiceAccount the scan jobs must run as."
  value       = azurerm_federated_identity_credential.trivy.subject
}
