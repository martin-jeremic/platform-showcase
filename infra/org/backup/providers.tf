provider "azurerm" {
  features {}

  subscription_id = var.subscription_id

  # Authenticate blob data-plane calls with the `az login` identity instead of an
  # account key. Required here, not optional: main.tf sets
  # shared_access_key_enabled = false, so the provider's default (fetch a key via
  # listKeys and use it) fails with
  #   403 KeyBasedAuthenticationNotPermitted: Key based authentication is not
  #   permitted on this storage account
  # while creating the container.
  #
  # ../../tfstate-bootstrap does not need this because that account leaves keys enabled
  # -- it has to, since the azurerm backend reads the state blob with an account key.
  # This stack has no such requirement, so keys stay off and this flag pays for it.
  #
  # Note the applier needs a data-plane role for this to work. Owner and Contributor
  # grant `actions: *` and no dataActions whatsoever, so neither is sufficient: the
  # applier also needs Storage Blob Data Contributor (or Data Owner) on the account.
  storage_use_azuread = true
}
