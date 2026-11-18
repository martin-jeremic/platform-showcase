variable "subscription_id" {
  description = "Shared-services subscription holding the registries. Null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "tenant_id" {
  description = "Entra tenant the grantees are looked up in."
  type        = string
  default     = null
}

# Not the repo's default region: the registries were created elsewhere and a
# registry cannot move region, so the live location wins.
variable "location" {
  description = "Region of the resource group and the registries."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Existing resource group of the registries (live name)."
  type        = string
  default     = "rg-container-registry"
}

# Keyed by live registry name, which is also the login server.
#
# admin_enabled is per registry because it already DIFFERS: one registry has the
# admin user on (a single shared push/pull password), the other does not. Turning it
# off is the right end state but a separate change, after confirming nothing still
# logs in with that password (README KNOWN-GAPS).
variable "registries" {
  description = "Registries in the resource group, keyed by name. All Basic SKU."
  type = map(object({
    admin_enabled = bool
  }))
  default = {
    orgacr     = { admin_enabled = true }
    productacr = { admin_enabled = false }
  }
}

# Every entry was imported from a grant that already existed. Keep this list here,
# not in terraform.tfvars: the committed default IS the managed set, and a
# git-ignored copy would hide access changes from review.
variable "role_assignments" {
  description = "Role assignments on the registries. Exactly one of `user` (UPN) or `client_id` (appId) per entry."
  type = list(object({
    registry  = string
    role      = string
    user      = optional(string)
    client_id = optional(string)
  }))
  default = [
    # Human push, for the rare manual hotfix image.
    { registry = "orgacr", role = "AcrPush", user = "release-manager@example.com" },

    # CI service connections (one per pipeline project).
    { registry = "orgacr", role = "AcrPush", client_id = "77777777-7777-7777-7777-777777777777" },
    { registry = "productacr", role = "AcrPush", client_id = "88888888-8888-8888-8888-888888888888" },

    # A scanner that lists repositories needs Reader on top of AcrPull.
    { registry = "orgacr", role = "AcrPull", client_id = "99999999-9999-9999-9999-999999999999" },
    { registry = "orgacr", role = "Reader", client_id = "99999999-9999-9999-9999-999999999999" },
  ]

  validation {
    condition     = alltrue([for g in var.role_assignments : (g.user == null) != (g.client_id == null)])
    error_message = "Each role assignment needs exactly one of `user` (a UPN) or `client_id` (an appId)."
  }

  validation {
    condition     = alltrue([for g in var.role_assignments : contains(keys(var.registries), g.registry)])
    error_message = "Each role assignment's registry must be a key of var.registries."
  }
}

# The import pass runs with this EMPTY, matching the untagged live objects, so the
# post-import plan can say "No changes." -- the proof the import is correct. The
# standard map lands in the second commit.
variable "tags" {
  description = "Tags on the resource group and the registries."
  type        = map(string)
  default     = {}
}
