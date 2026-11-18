terraform {
  required_version = ">= 1.9"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.9"
    }
  }

  # No backend and no provider block on purpose. The provider is REALM-scoped:
  # every environment authenticates with its own `terraform-provisioner`
  # credential against its own URL, which belongs to the root, not to a module.
}
