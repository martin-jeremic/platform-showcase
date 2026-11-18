terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    # The app registration Alertmanager authenticates to Microsoft Graph as.
    # Directory plane, so it needs its own role for the applier (README).
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }

    # Drives client-secret rotation (entra.tf).
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }

    # Read-only here: azurerm does not expose an API connection's authorization
    # status, which the check in teams.tf needs.
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }

  # This state holds both notification credentials in plaintext (the Graph client
  # secret and the Logic App trigger URL, per destination). Read access to the
  # state blob is read access to them.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "alerting.tfstate"
  }
}
