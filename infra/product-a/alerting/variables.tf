variable "subscription_id" {
  description = "Subscription for the resource group, the Logic Apps and the Teams API connection (where the clusters' egress IPs live)."
  type        = string
  default     = "33333333-3333-3333-3333-333333333333"
}

variable "key_vault_subscription_id" {
  description = "Shared-services subscription holding the per-environment Key Vaults."
  type        = string
  default     = "22222222-2222-2222-2222-222222222222"
}

variable "tenant_id" {
  description = "Entra tenant to create the app registration in. Pinned so an apply cannot land in the wrong directory."
  type        = string
  default     = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
}

variable "location" {
  description = "Region for the resource group, the Logic Apps and the Teams API connection."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group holding the Logic Apps and the Teams API connection."
  type        = string
  default     = "rg-alerting"
}

variable "app_display_name" {
  description = "Display name of the Entra app Alertmanager sends mail as. Also names its Exchange pointer, scope and role assignment."
  type        = string
  default     = "platform-alerting"
}

variable "key_vault_resource_group_name" {
  description = "Resource group of the per-environment Key Vaults (the same for every cluster)."
  type        = string
  default     = "rg-keyvaults"
}

variable "object_prefix" {
  description = "Prefix of the Key Vault objects. Must equal notifications.keyVault.objectPrefix in the observability chart, whose SecretProviderClass mounts exactly these names."
  type        = string
  default     = "alertmanager"
}

variable "secret_rotation_days" {
  description = "Age after which the next `tofu apply` replaces a cluster's Graph client secret."
  type        = number
  default     = 180
}

variable "secret_lifetime" {
  description = "Lifetime of each Graph client secret, as a timeadd() duration from its rotation start. Must exceed secret_rotation_days."
  type        = string
  default     = "8760h" # 365 days

  validation {
    condition     = can(timeadd("2000-01-01T00:00:00Z", var.secret_lifetime))
    error_message = "secret_lifetime must be a duration timeadd() accepts, such as 8760h."
  }
}

# teams_channels and clusters are COMMITTED defaults, not terraform.tfvars values:
# the default IS the managed set. Which clusters notify, into which vault, which
# channel and as which mailbox is reviewed like any other change. None of it is a
# secret, and a terraform.tfvars that sets it silently replaces the default with a
# value no review has seen.

variable "teams_channels" {
  description = <<-EOT
    Teams channels alert cards are posted to, by name. A channel's IDs are written
    once however many destinations post to it.
      team_id     the team (M365 group) ID: the groupId= of the channel link
      channel_id  19:...@thread.tacv2, URL-decoded from the channel link
    The Teams service account must be a member of every team named here.
  EOT
  type = map(object({
    team_id    = string
    channel_id = string
  }))

  default = {
    "platform-general" = {
      team_id    = "44444444-4444-4444-4444-444444444444"
      channel_id = "19:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@thread.tacv2"
    }
    "product-a-non-prod" = {
      team_id    = "44444444-4444-4444-4444-444444444444"
      channel_id = "19:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb@thread.tacv2"
    }
    "product-a-prod" = {
      team_id    = "44444444-4444-4444-4444-444444444444"
      channel_id = "19:cccccccccccccccccccccccccccccccc@thread.tacv2"
    }
  }

  validation {
    condition     = alltrue([for c in values(var.teams_channels) : can(regex("^[0-9a-fA-F-]{36}$", c.team_id))])
    error_message = "Each team_id must be the team's group ID (a GUID), the groupId= value of the Teams link."
  }

  validation {
    condition     = alltrue([for c in values(var.teams_channels) : can(regex("^19:[^@]+@thread\\.(tacv2|skype)$", c.channel_id))])
    error_message = "Each channel_id must be the URL-decoded channel ID, 19:...@thread.tacv2 (decode %3A to : and %40 to @)."
  }
}

variable "clusters" {
  description = <<-EOT
    One entry per cluster whose Alertmanager notifies. Each gets its own Graph
    client secret (so one cluster's secret rotates and revokes on its own) and one
    Logic App and trigger URL per destination, all written to its own vault.

      key_vault_name    the cluster's vault, in key_vault_resource_group_name
      teams_channel     the channel this cluster's own alerts post to
      sender            mailbox alerts are sent FROM; must equal
                        notifications.graph.sender in the cluster's overlay. A NEW
                        sender = apply, then re-run the Exchange script.
      egress_public_ip  optional static outbound IP (name + RG). When set, the
                        cluster's Logic App triggers accept calls only from it.
      audiences         optional further destinations on THIS Alertmanager. A hub
                        evaluates alerts for spokes that have no Alertmanager of
                        their own, and those can belong to other people. Each is
                        { teams_channel, sender } and must match
                        notifications.audiences.<name> in the overlay.
  EOT
  type = map(object({
    key_vault_name = string
    teams_channel  = string
    sender         = string
    egress_public_ip = optional(object({
      name                = string
      resource_group_name = string
    }))
    audiences = optional(map(object({
      teams_channel = string
      sender        = string
    })), {})
  }))

  default = {
    # The on-prem hub. Its own alerts -> the platform channel. The product spoke it
    # evaluates (product-a-stage ships metrics to the hub) -> the product channel,
    # sent as the product mailbox.
    "hub-dev" = {
      key_vault_name = "kv-org-dev"
      teams_channel  = "platform-general"
      sender         = "alerts@example.com"
      audiences = {
        product-a = {
          teams_channel = "product-a-non-prod"
          sender        = "product-a-alerts@example.com"
        }
      }
    }
    "aks-product-a-prod" = {
      key_vault_name = "kv-product-a-prod"
      teams_channel  = "product-a-prod"
      sender         = "product-a-alerts@example.com"
      egress_public_ip = {
        name                = "pip-product-a-prod-aks-outbound"
        resource_group_name = "rg-product-a-prod"
      }
    }
  }

  validation {
    condition = alltrue(flatten([for c in values(var.clusters) : concat(
      [contains(keys(var.teams_channels), c.teams_channel)],
      [for a in values(c.audiences) : contains(keys(var.teams_channels), a.teams_channel)],
    )]))
    error_message = "Every teams_channel, a cluster's own and each audience's, must be a key of teams_channels."
  }

  validation {
    condition = alltrue([for s in flatten([for c in values(var.clusters) : concat([c.sender], [for a in values(c.audiences) : a.sender])]) :
    can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", s))])
    error_message = "Each sender, a cluster's own and each audience's, must be a single email address."
  }

  validation {
    condition     = alltrue([for k in keys(var.clusters) : can(regex("^[a-z0-9-]{1,40}$", k))])
    error_message = "Cluster keys must be lowercase letters, digits and '-' (they become part of resource names)."
  }

  validation {
    condition     = alltrue(flatten([for c in values(var.clusters) : [for k in keys(c.audiences) : can(regex("^[a-z0-9-]{1,30}$", k))]]))
    error_message = "Audience keys must be lowercase letters, digits and '-', at most 30: they become part of Logic App and Key Vault object names."
  }
}

variable "tags" {
  description = "Tags applied to all Azure resources."
  type        = map(string)
  default = {
    workload   = "alerting"
    managed_by = "opentofu"
  }
}
