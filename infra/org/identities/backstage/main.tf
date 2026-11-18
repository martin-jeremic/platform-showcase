terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "~> 1.0"
    }
    # The portal's session-signing secret (session-secret.tf).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "org-identity-backstage.tfstate"
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

provider "azuredevops" {
  org_service_url = var.ado_org_url
}

# The developer portal (Backstage) on the hub reads Azure DevOps and Key Vault with
# an Entra token instead of a PAT or a service-principal secret. Same shape as
# ../argocd-git: a projected ServiceAccount token signed by the hub's own
# apiserver, exchanged by Entra for a token of the identity below. Azure DevOps
# accepts it because the identity is an org member (devops.tf); Key Vault because
# it holds Secrets User on the vault (keyvault.tf). Nothing stored, nothing expires.

resource "azurerm_resource_group" "backstage" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_user_assigned_identity" "backstage" {
  name                = var.identity_name
  resource_group_name = azurerm_resource_group.backstage.name
  location            = azurerm_resource_group.backstage.location
  tags                = var.tags
}

# `subject` is compared verbatim. A renamed ServiceAccount (chart value
# serviceAccount.name) or a moved namespace silently stops authenticating with
# AADSTS700213. The chart's projected token and the Key Vault CSI driver request
# the same audience.
resource "azurerm_federated_identity_credential" "backstage" {
  name                      = "hub-dev-${var.backstage_namespace}-${var.backstage_service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.backstage.id

  issuer   = var.oidc_issuer_url
  subject  = "system:serviceaccount:${var.backstage_namespace}:${var.backstage_service_account}"
  audience = ["api://AzureADTokenExchange"]
}
