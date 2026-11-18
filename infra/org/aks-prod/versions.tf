terraform {
  # 1.9+ for cross-variable references in validation blocks.
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    # Creates the Entra groups that back cluster access. Directory plane, so the
    # applier needs Groups Administrator (or owns the groups).
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "org-aks-prod.tfstate"
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

# Leaving tenant_id null infers the tenant from `az login`; pinning it makes an
# apply fail fast instead of creating groups in the wrong directory.
provider "azuread" {
  tenant_id = var.tenant_id
}
