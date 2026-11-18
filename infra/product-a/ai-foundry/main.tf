terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.20"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.2"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "product-a-ai-foundry.tfstate"
  }
}

# Azure CLI auth (`az login`); no service principal secret is configured here.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# In current Foundry the "account" is a Cognitive Services resource of kind
# AIServices with project management enabled.
resource "azurerm_cognitive_account" "foundry" {
  name                = var.foundry_account_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  kind     = "AIServices"
  sku_name = "S0"

  # Required for Foundry accounts; also forms the endpoint URL.
  custom_subdomain_name = var.foundry_account_name

  # azurerm 4.20+ exposes this natively, so the earlier azapi PATCH workaround is
  # gone. Leaving it unset defaults to false, which forces the account to be
  # REPLACED -- never let a plan do that.
  project_management_enabled = true

  # Key-based auth stays on because the consumers authenticate with a key today;
  # see the outputs note. Turning it off (local_auth_enabled = false) is the
  # follow-up once every caller uses Entra tokens.
  local_auth_enabled = var.local_auth_enabled

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

# The Foundry project (child of the account). No stable azurerm resource exists
# yet, so azapi.
resource "azapi_resource" "project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name      = var.project_name
  parent_id = azurerm_cognitive_account.foundry.id
  location  = azurerm_resource_group.this.location

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      displayName = var.project_display_name
      description = "Foundry project managed by OpenTofu (product-a/ai-foundry)."
    }
  }

  tags = var.tags

  response_export_values = ["identity.principalId"]
}

resource "azurerm_cognitive_deployment" "model" {
  name                 = var.deployment_name
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = var.model_format
    name    = var.model_name
    version = var.model_version
  }

  sku {
    name     = var.deployment_sku_name
    capacity = var.deployment_capacity
  }

  # The project must exist before the deployment is created against the account.
  depends_on = [azapi_resource.project]
}
