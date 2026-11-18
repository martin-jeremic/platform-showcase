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
    key                  = "keycloak-product-a-prod.tfstate"
  }
}

provider "keycloak" {
  client_id      = "terraform-provisioner"
  client_secret  = var.provisioner_client_secret
  url            = var.keycloak_url
  realm          = var.realm_name
  client_timeout = 30
}

locals {
  # One realm-management role per Keycloak admin REST call the admin API makes:
  # view-users (read a user), view-realm (list holders of the admin realm roles),
  # manage-users (delete an account). Same set every environment grants.
  admin_api_realm_management_roles = ["manage-users", "view-realm", "view-users"]

  app_hostnames = ["app.product-a.example.net", "app.product-a.example.org"]
}

# Argo CD and Grafana are NOT configured in the module. They exist only on this
# cluster, so they live in platform-clients.tf next to this call (module = what
# every realm has; root = what this realm has that the others do not).
module "realm" {
  source = "../modules/realm"

  realm_name = var.realm_name
  env        = "prod"

  canonical_app_url = "https://${local.app_hostnames[0]}"
  app_redirect_uris = [for h in local.app_hostnames : "https://${h}/*"]
  app_web_origins   = [for h in local.app_hostnames : "https://${h}"]

  # Required because this realm is greenfield: the backend runs the code flow, and
  # the provider refuses to CREATE such a client with no redirect URI. Dev never hit
  # the check because its client was imported, not created.
  api_redirect_uris = [for h in local.app_hostnames : "https://${h}/*"]

  admin_api_realm_management_roles = local.admin_api_realm_management_roles

  # FALSE HERE. The module defaults to true to match dev, but this login page is
  # public and fronts Argo CD and Grafana; open self-registration would let anyone
  # mint an account in the realm that guards them.
  registration_allowed = false

  manage_realm = true
}
