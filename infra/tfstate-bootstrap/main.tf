terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # Intentionally NO backend block. This config creates the storage account that
  # every other stack uses for remote state, so its own state cannot live there on
  # the first apply (chicken-and-egg). The resources are created once and almost
  # never change, so local state is acceptable here.
  #
  # Optional second step (what the org repository did): once the account exists,
  # add a backend block with key "tfstate-bootstrap.tfstate" and run
  # `tofu init -migrate-state`, so this state does not live on exactly one laptop.
  # Keep this comment so the next person understands why the first apply had to
  # run locally. See ../docs/state-backend-runbook.md.
}

provider "azurerm" {
  features {}

  # Null falls back to ARM_SUBSCRIPTION_ID. Pin it on every command rather than
  # relying on `az account set` (see ../docs/import-methodology.md, rule 10).
  subscription_id = var.subscription_id
}

locals {
  tags = {
    purpose    = "terraform-state"
    managed_by = "opentofu"
  }
}

# Dedicated resource group for state. Kept separate from every workload resource
# group so a `tofu destroy` of any stack can never reach the state that describes it.
resource "azurerm_resource_group" "tfstate" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# One shared, team-wide state account. Every stack stores its state here as a
# separate blob (the backend `key`), so adding a stack costs one line, not new
# infrastructure.
resource "azurerm_storage_account" "tfstate" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.tfstate.name
  location                 = azurerm_resource_group.tfstate.location
  account_tier             = "Standard"
  account_replication_type = var.replication_type
  access_tier              = "Hot"

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false

  # shared_access_key_enabled stays at its default (true) on purpose: the azurerm
  # backend reads the state blob with an account key unless every operator and
  # pipeline is moved to `use_azuread_auth = true`. That move is listed in the
  # README KNOWN-GAPS. The backup stack (../org/backup) shows the keys-off shape.

  # Versioning + soft delete are the main safety net for state: every write keeps
  # the previous copy, and a deleted blob or container can be undeleted. This
  # protects the state FILE, not the Azure resources it describes.
  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = var.soft_delete_days
    }

    container_delete_retention_policy {
      days = var.soft_delete_days
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

resource "azurerm_storage_container" "tfstate" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# The Azure-side half of the guard. prevent_destroy only constrains OpenTofu; this
# lock also stops the portal and the CLI. Needs Owner or User Access Administrator.
resource "azurerm_management_lock" "tfstate" {
  name       = "tfstate-no-delete"
  scope      = azurerm_storage_account.tfstate.id
  lock_level = "CanNotDelete"
  notes      = "Holds OpenTofu remote state for every stack. Do not delete."
}
