terraform {
  required_version = ">= 1.9"

  required_providers {
    # Pinned to the minor whose behaviour this module relies on (Optional+Computed
    # reads, the redirect-URI guard, realm `attributes` tracking only configured
    # keys, import formats) -- each verified against the provider source.
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.9"
    }
  }
}
