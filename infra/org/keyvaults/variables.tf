variable "subscription_id" {
  description = "Shared-services subscription holding the vaults. Null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "tenant_id" {
  description = "Entra tenant the grantees are looked up in."
  type        = string
  default     = null
}

variable "location" {
  description = "Region of the resource group. Each vault has its own location."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Existing resource group of the vaults."
  type        = string
  default     = "rg-keyvaults"
}

# Keyed by LIVE vault name. A Key Vault rename is a destroy-and-create of the thing
# that holds the secrets, so live names win. Locations are live too: several regions.
#
# network_acls is set exactly where the live vault has an explicit rule set. The
# newer vaults were created with { bypass = None, default_action = Allow } --
# functionally open, like the older ones that have no rule set at all. Recorded as
# found; tightening either is a separate decision (README KNOWN-GAPS).
variable "vaults" {
  description = "Key Vaults in the resource group, keyed by name."
  type = map(object({
    location = string
    network_acls = optional(object({
      bypass         = string
      default_action = string
    }))
  }))
  default = {
    "kv-org-dev"         = { location = "swedencentral" }
    "kv-org-prod"        = { location = "swedencentral" }
    "kv-product-a-dev"   = { location = "germanywestcentral", network_acls = { bypass = "None", default_action = "Allow" } }
    "kv-product-a-stage" = { location = "germanywestcentral", network_acls = { bypass = "None", default_action = "Allow" } }
    "kv-product-a-demo"  = { location = "germanywestcentral", network_acls = { bypass = "None", default_action = "Allow" } }
    "kv-product-a-prod"  = { location = "germanywestcentral", network_acls = { bypass = "None", default_action = "Allow" } }
  }
}

variable "role_assignments" {
  description = "Role assignments on the vaults (`vault` set) or on their resource group (`vault` omitted). Exactly one of `user` or `client_id` per entry."
  type = list(object({
    vault     = optional(string)
    role      = string
    user      = optional(string)
    client_id = optional(string)
  }))
  default = [
    # Platform engineers seed and rotate secrets.
    { vault = "kv-org-dev", role = "Key Vault Secrets Officer", user = "platform-admin@example.com" },
    { vault = "kv-org-prod", role = "Key Vault Secrets Officer", user = "platform-admin@example.com" },
    { vault = "kv-product-a-prod", role = "Key Vault Secrets Officer", user = "platform-admin@example.com" },

    # The hub's identity reading the dev vault (on-prem cluster, federated identity).
    { vault = "kv-org-dev", role = "Key Vault Secrets User", client_id = "cccccccc-cccc-cccc-cccc-cccccccccccc" },

    # CI service connection that applies the alerting and postgres stacks.
    { vault = "kv-product-a-prod", role = "Key Vault Secrets Officer", client_id = "77777777-7777-7777-7777-777777777777" },

    # Resource-group scope (no `vault`): a legacy deployment principal.
    { role = "Key Vault Contributor", client_id = "88888888-8888-8888-8888-888888888888" },
  ]

  validation {
    condition     = alltrue([for g in var.role_assignments : (g.user == null) != (g.client_id == null)])
    error_message = "Each role assignment needs exactly one of `user` (a UPN) or `client_id` (an appId)."
  }

  validation {
    condition     = alltrue([for g in var.role_assignments : g.vault == null || contains(keys(var.vaults), coalesce(g.vault, "-"))])
    error_message = "A role assignment's vault must be a key of var.vaults (or omitted for resource-group scope)."
  }
}

variable "tags" {
  description = "Tags on the resource group and the vaults. Empty during the import pass; the standard map lands in the second commit."
  type        = map(string)
  default = {
    workload   = "keyvaults"
    managed_by = "opentofu"
  }
}
