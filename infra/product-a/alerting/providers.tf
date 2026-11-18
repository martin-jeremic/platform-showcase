# The subscription holding the Logic Apps, the Teams API connection and the
# clusters' egress IPs.
provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

# The per-environment Key Vaults live in the shared-services subscription. Vault
# lookups and vault writes (keyvault.tf) run through this alias.
provider "azurerm" {
  alias = "shared"
  features {}

  subscription_id = var.key_vault_subscription_id
}

# Directory plane. Pinned so an apply fails fast instead of creating the app
# registration in the wrong directory when someone is signed into several tenants.
provider "azuread" {
  tenant_id = var.tenant_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}
