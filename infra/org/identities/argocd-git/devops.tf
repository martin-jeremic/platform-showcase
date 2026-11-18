# An identity existing in the tenant is NOT implicitly trusted by Azure DevOps. It
# must be added to the organisation (an entitlement, which takes a licence seat)
# and granted read on each project -- the step most often missed.

# Basic, not Stakeholder: Stakeholder has no access to Repos in private projects.
#
# "express" IS Basic -- it is the licensing API's name for it. Do not write
# "basic": the provider accepts it in validation but sends the string through
# unconverted, the API does not know it, falls back to None, and fails with
#   (5000) A user cannot be assigned an Account-None license.
resource "azuredevops_service_principal_entitlement" "argocd" {
  origin_id            = azurerm_user_assigned_identity.argocd.principal_id
  account_license_type = "express"
}

data "azuredevops_project" "readable" {
  for_each = toset(var.ado_projects)
  name     = each.key
}

# The built-in Readers group of each project carries Code (Read).
data "azuredevops_group" "readers" {
  for_each   = data.azuredevops_project.readable
  project_id = each.value.id
  name       = "Readers"
}

# mode "add" (the default) only adds this member; existing members are left alone.
resource "azuredevops_group_membership" "readers" {
  for_each = data.azuredevops_group.readers
  group    = each.value.descriptor
  members  = [azuredevops_service_principal_entitlement.argocd.descriptor]
}
