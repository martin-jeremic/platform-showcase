terraform {
  required_version = ">= 1.9"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.9"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "keycloak-product-a-dev.tfstate"
  }
}

# Client-credentials auth against the TARGET realm itself, so this credential
# cannot reach any other realm -- strictly narrower than the master-realm superuser
# the earlier shell scripts used. Created by ../bootstrap-provisioner.sh.
provider "keycloak" {
  client_id      = "terraform-provisioner"
  client_secret  = var.provisioner_client_secret
  url            = var.keycloak_url
  realm          = var.realm_name
  client_timeout = 30
}

locals {
  # The realm-management roles the live backend service account holds. Declared so
  # the grant is drift-detected; whether it needs all three is a separate review.
  api_realm_management_roles = ["manage-users", "view-realm", "view-users"]
}

module "realm" {
  source = "../modules/realm"

  realm_name = var.realm_name
  env        = "dev"

  canonical_app_url = "https://dev.example.com/product-a"
  app_redirect_uris = ["https://dev.example.com/product-a/*"]
  app_web_origins   = ["https://dev.example.com"]

  # api_redirect_uris deliberately not passed: dev's backend is a pure service
  # account, so its standard flow derives to off (see the module variable).
  api_realm_management_roles       = local.api_realm_management_roles
  admin_api_realm_management_roles = local.api_realm_management_roles

  # Stays false until every leaf object is adopted and plans clean; the realm itself
  # is adopted last, on its own (../../../docs/keycloak-consolidation.md).
  manage_realm = false
}
