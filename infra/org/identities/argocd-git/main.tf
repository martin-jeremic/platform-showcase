terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    # Adds the identity to the Azure DevOps organisation and to each project's
    # Readers group -- the part an Entra identity does NOT get implicitly.
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "~> 1.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "org-identity-argocd-git.tfstate"
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

# Signs in with the `az login` session, so applying needs no PAT either. Do not
# export AZDO_PERSONAL_ACCESS_TOKEN: if it is set, the provider uses it instead.
provider "azuredevops" {
  org_service_url = var.ado_org_url
}

# The hub's Argo CD reads Azure DevOps git with an Entra token instead of PATs.
#
# The hub is an ON-PREM MicroK8s cluster, not AKS, so there is no Azure-hosted
# OIDC issuer. Its kube-apiserver signs ServiceAccount tokens with its own key, and
# platform/charts/oidc-issuer publishes the discovery document and JWKS at a public
# HTTPS URL. Entra exchanges the repo-server's projected token for a token of the
# identity below -- only when issuer, subject and audience match exactly -- and
# Azure DevOps accepts that token because the identity is an org member and a
# Reader in the projects (devops.tf). Nothing is stored and nothing expires.

resource "azurerm_resource_group" "argocd" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# User-assigned managed identity rather than an app registration: nobody can ever
# add a client secret to it, so it cannot drift back into a stored, expiring
# credential.
resource "azurerm_user_assigned_identity" "argocd" {
  name                = var.identity_name
  resource_group_name = azurerm_resource_group.argocd.name
  location            = azurerm_resource_group.argocd.location
  tags                = var.tags
}

# The trust anchor. `subject` is compared verbatim -- no wildcard, no prefix match.
# A renamed repo-server ServiceAccount or a moved Argo CD namespace silently stops
# authenticating; the repo-server log names the subject it presented, so check that
# first. The audience is the fixed constant Entra requires for this flow.
resource "azurerm_federated_identity_credential" "argocd" {
  name                      = "hub-dev-${var.argocd_namespace}-${var.repo_server_service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.argocd.id

  issuer   = var.oidc_issuer_url
  subject  = "system:serviceaccount:${var.argocd_namespace}:${var.repo_server_service_account}"
  audience = ["api://AzureADTokenExchange"]
}
