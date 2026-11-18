terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "org-keyvaults.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      # The provider default PURGES a vault the moment OpenTofu deletes it. Off: a
      # vault deleted through this stack -- possible only after prevent_destroy and
      # the lock are lifted -- stays recoverable for its soft-delete retention.
      purge_soft_delete_on_destroy = false
    }
  }

  subscription_id = var.subscription_id
}

provider "azuread" {
  tenant_id = var.tenant_id
}

data "azurerm_client_config" "current" {}

# ADOPTED BY IMPORT. The vaults ARE the secret store -- the only copy of the
# application credentials -- so the group and every vault carry prevent_destroy,
# and the group carries a CanNotDelete lock (added in the second commit after the
# import). The two fail in different directions: prevent_destroy stops OpenTofu,
# the lock stops the portal and the CLI.
#
# Secrets, keys and certificates are DATA PLANE and deliberately not managed here
# (rule 9): importing them would put secret material in state. The exceptions are
# objects a stack generates itself and writes straight in (alerting, postgres app
# roles, backstage), each owned by that stack.

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_key_vault" "kv" {
  for_each = var.vaults

  name                = each.key
  location            = each.value.location
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id

  # Identical on every live vault, so stated once. Some vaults report their SKU as
  # "Standard", others as "standard"; the provider accepts only lower case.
  sku_name                        = "standard"
  rbac_authorization_enabled      = true
  soft_delete_retention_days      = 90
  public_network_access_enabled   = true
  enabled_for_deployment          = false
  enabled_for_disk_encryption     = false
  enabled_for_template_deployment = false

  # ON. The import ran with the live value (off) so its plan stayed a no-op, and
  # turning it on was its own reviewed change afterwards, because it is
  # IRREVERSIBLE: once on it can never be turned off, and it blocks purging the
  # vault for its lifetime. That is exactly the property a secret store wants --
  # soft delete alone still lets anyone with purge rights make a deletion final.
  purge_protection_enabled = true

  # Only where the live vault has an explicit rule set. `[*]` on a null object is
  # an empty list and on an object a one-element list, so `optional(object)` maps
  # straight onto "block or no block". network_acls is Optional+Computed, so
  # leaving it out on the others plans no change.
  dynamic "network_acls" {
    for_each = each.value.network_acls[*]

    content {
      bypass         = network_acls.value.bypass
      default_action = network_acls.value.default_action
    }
  }

  # No access_policy blocks. With RBAC authorisation on, the data plane ignores
  # access policies entirely; legacy entries still stored on older vaults are inert.
  # The argument is Optional+Computed, so leaving it out neither manages nor
  # removes them.

  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

resource "azurerm_management_lock" "keyvaults" {
  name       = "keyvaults-no-delete"
  scope      = azurerm_resource_group.rg.id
  lock_level = "CanNotDelete"
  notes      = "Holds the only copy of the application secrets. Managed by infra/org/keyvaults."
}
