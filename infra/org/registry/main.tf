terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    # Read-only here: resolves each grantee in rbac.tf from a UPN or appId to the
    # object id a role assignment needs.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "org-registry.tfstate"
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

provider "azuread" {
  tenant_id = var.tenant_id
}

# ADOPTED BY IMPORT (imports.tf.example, ../../docs/import-methodology.md).
#
# The resource group and the registries carry prevent_destroy. A registry's name is
# its login server (<name>.azurecr.io), baked into every image reference in every
# chart, so a rename -- ForceNew -- would break every deployment at once, and old
# tags cannot always be rebuilt because the source has moved on.
#
# No management lock, deliberately: the images are not the only copy of anything,
# which is the bar the SQL and backup locks were set against.

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_container_registry" "acr" {
  for_each = var.registries

  name                = each.key
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = each.value.admin_enabled

  # EVERY value below is the live setting, stated so the import plan compares
  # against the registry rather than against a provider default. Most are Premium
  # features a Basic registry reports in their off position. Leaving any of them to
  # the default is how an import plan grows an "update in-place" nobody asked for.
  # retention_policy_in_days is the one left out (Premium-only; it reads back with
  # a stored value while disabled -- if the plan shows it, copy the live value).
  public_network_access_enabled                = true
  network_rule_bypass_option                   = "AzureServices"
  network_rule_bypass_for_tasks_enabled        = false
  anonymous_pull_enabled                       = false
  data_endpoint_enabled                        = false
  export_policy_enabled                        = true
  quarantine_policy_enabled                    = false
  trust_policy_enabled                         = false
  zone_redundancy_enabled                      = false
  azuread_authentication_as_arm_policy_enabled = true

  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}
