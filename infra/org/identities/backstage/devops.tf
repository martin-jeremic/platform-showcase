# Basic ("express" -- see ../argocd-git/devops.tf for why not "basic"): catalog
# discovery uses Code Search over every repository, which Stakeholder cannot.
resource "azuredevops_service_principal_entitlement" "backstage" {
  origin_id            = azurerm_user_assigned_identity.backstage.principal_id
  account_license_type = "express"
}

data "azuredevops_project" "readable" {
  for_each = toset(var.ado_read_projects)
  name     = each.key
}

# Readers: Code (Read) and Build (Read) -- catalog discovery, README, pipeline and
# pull-request cards.
data "azuredevops_group" "readers" {
  for_each   = data.azuredevops_project.readable
  project_id = each.value.id
  name       = "Readers"
}

resource "azuredevops_group_membership" "readers" {
  for_each = data.azuredevops_group.readers
  group    = each.value.descriptor
  members  = [azuredevops_service_principal_entitlement.backstage.descriptor]
}

# Software templates create repositories and pipelines and open pull requests, in
# these projects only. Main stays protected by branch policies, so a template's
# change to an existing repository still needs a reviewed PR.
data "azuredevops_project" "writable" {
  for_each = toset(var.ado_write_projects)
  name     = each.key
}

data "azuredevops_group" "contributors" {
  for_each   = data.azuredevops_project.writable
  project_id = each.value.id
  name       = "Contributors"
}

resource "azuredevops_group_membership" "contributors" {
  for_each = data.azuredevops_group.contributors
  group    = each.value.descriptor
  members  = [azuredevops_service_principal_entitlement.backstage.descriptor]
}
