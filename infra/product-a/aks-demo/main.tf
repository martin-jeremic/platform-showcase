provider "azurerm" {
  features {}

  # Null falls back to ARM_SUBSCRIPTION_ID. demo.tfvars.example pins it so a run
  # never silently targets whatever `az account show` happens to say.
  subscription_id = var.subscription_id
}

# The shared registry and the per-environment Key Vaults live in the
# shared-services subscription, not in the one hosting this cluster. This alias
# targets it so the role assignments in identity-access.tf and trivy-identity.tf
# land in the right subscription. Same Entra tenant, so no extra auth config.
provider "azurerm" {
  alias = "shared"
  features {}

  subscription_id = var.shared_subscription_id
}

locals {
  tags = {
    project    = "product-a"
    env        = "demo"
    managed_by = "opentofu"
  }
}

resource "azurerm_resource_group" "demo" {
  name     = "rg-product-a-demo"
  location = var.location
  tags     = local.tags
}
