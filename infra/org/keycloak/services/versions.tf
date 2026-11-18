terraform {
  # Import blocks with for_each (the generated imports-*.tf files) need 1.7+.
  required_version = ">= 1.9"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.9"
    }
  }

  # One state blob per Keycloak INSTANCE. This is the production instance; the dev
  # root has its own key. `az login` is a prerequisite even though nothing here
  # talks to ARM: the state lives in the shared storage account.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "org-keycloak-services.tfstate"
  }
}

# One provider, authenticated instance-wide against `master` with client
# credentials as the `tofu-provisioner` service account created by
# ../../../scripts/keycloak/kc_bootstrap.py. Instance-wide because this root owns
# every in-scope realm on the instance, the realm objects included, and creating a
# realm is only possible from `master`.
#
# `base_path` is not optional: the deployment sets KC_HTTP_RELATIVE_PATH=/keycloak,
# and without it every admin API call 404s with no useful error.
provider "keycloak" {
  client_id     = var.provisioner_client_id
  client_secret = var.provisioner_client_secret

  url       = var.keycloak_url
  base_path = var.keycloak_base_path
  realm     = "master"

  client_timeout = 60
}
