provider "azurerm" {
  features {}

  subscription_id = var.subscription_id

  # Blob data-plane calls (container creation) use the applier's Entra identity
  # instead of fetching an account key, so storage.tf can turn keys off.
  storage_use_azuread = true
}

# Registry and per-environment Key Vaults live in the shared-services
# subscription. Same Entra tenant, so the alias needs no extra auth config.
provider "azurerm" {
  alias = "shared"
  features {}

  subscription_id = var.shared_subscription_id
}

# Tenant ID for the PostgreSQL Entra authentication block (postgres.tf).
data "azurerm_client_config" "current" {}

locals {
  tags = {
    project    = "product-a"
    env        = "prod"
    managed_by = "opentofu"
  }
}

resource "azurerm_resource_group" "prod" {
  name     = "rg-product-a-prod"
  location = var.location
  tags     = local.tags
}
