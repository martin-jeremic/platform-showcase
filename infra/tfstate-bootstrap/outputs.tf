# Copy into the backend "azurerm" block of any stack. Only `key` differs per stack.
output "backend_config" {
  description = "Values for the backend \"azurerm\" block in consumer stacks."
  value = {
    resource_group_name  = azurerm_resource_group.tfstate.name
    storage_account_name = azurerm_storage_account.tfstate.name
    container_name       = azurerm_storage_container.tfstate.name
  }
}
