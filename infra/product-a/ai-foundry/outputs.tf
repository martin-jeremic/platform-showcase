# No API key is exported. The source had primary/secondary key outputs and a
# "connection" object embedding the key: sensitive = true hides it from the CLI
# but it still sits in state and in `tofu output -json`, and every reader of the
# outputs becomes a key holder.
#
# Consumers get the key at RUNTIME instead:
#   - preferred: no key at all -- the workload's managed identity holds
#     "Cognitive Services OpenAI User" on the account, and local_auth_enabled goes
#     false;
#   - until then: the key lives in the environment's Key Vault, put there with
#       az cognitiveservices account keys list -n <account> -g <rg> --query key1 -o tsv |
#         az keyvault secret set --vault-name kv-product-a-<env> --name llm--api-key --file /dev/stdin
#     and mounted through the Key Vault CSI driver. Rotating is `keys regenerate`
#     plus the same pipe, with no tofu run.

output "resource_group_name" {
  description = "Resource group holding the Foundry resources."
  value       = azurerm_resource_group.this.name
}

output "foundry_endpoint" {
  description = "Endpoint URL of the Foundry account."
  value       = azurerm_cognitive_account.foundry.endpoint
}

output "foundry_account_id" {
  description = "Resource ID of the account; the scope for role assignments such as Cognitive Services OpenAI User."
  value       = azurerm_cognitive_account.foundry.id
}

output "project_id" {
  description = "Resource ID of the Foundry project."
  value       = azapi_resource.project.id
}

output "model_deployment" {
  description = "Everything a caller needs except a credential."
  value = {
    endpoint        = azurerm_cognitive_account.foundry.endpoint
    deployment_name = azurerm_cognitive_deployment.model.name
    model_name      = azurerm_cognitive_deployment.model.model[0].name
    model_version   = azurerm_cognitive_deployment.model.model[0].version
  }
}
