# Notification credentials for Alertmanager on every cluster.
#
# Alertmanager runs in each cluster (platform/charts/observability). Its config
# reads these files, mounted from the cluster's Key Vault by the Secrets Store CSI
# driver:
#
#   <object_prefix>--graph-client-secret  -> oauth2 client_secret_file of the Graph
#                                            /sendMail webhook (all severities)
#   <object_prefix>--teams-webhook-url    -> msteamsv2 webhook_url_file (critical)
#   <object_prefix>--<audience>-teams-webhook-url
#                                         -> the same, for each audience: a second
#                                            channel on ONE Alertmanager (the hub's
#                                            spokes)
#
# This stack owns everything behind those files, so nothing is created by hand and
# no credential passes through a person:
#
#   entra.tf     the app registration and one rotating client secret per cluster
#   teams.tf     one Logic App per destination that turns Alertmanager's card into a
#                Teams channel post, plus the one shared Teams API connection
#   keyvault.tf  every value written straight into each cluster's vault
#
# Two steps cannot be expressed here and are done once (README.md):
#   - authorising the Teams API connection (an OAuth sign-in as a service account);
#   - scoping Mail.Send to the sender mailboxes in Exchange Online
#     (exchange/Set-AlertingSenderScope.ps1). No provider or Graph API exists for it.
#
# The same code ran in both repositories (one app registration per repository);
# this copy carries the superset: per-cluster vault lookup and egress allow-list
# from the product stack, audiences from the org stack.

locals {
  # Appended to descriptions so whoever finds these objects in the portal knows
  # where they came from. Entra descriptions are plain text -- no markdown.
  provenance = "Created by OpenTofu (infra/product-a/alerting)."

  tags = merge(var.tags, { source = "infra/product-a/alerting" })

  # Every Teams destination: each cluster's own channel, keyed "<cluster>" (the
  # keys the Logic Apps had before audiences existed, so their addresses never
  # moved), and one per audience, keyed "<cluster>/<audience>". teams.tf and
  # keyvault.tf iterate this. The Graph secret stays per CLUSTER (entra.tf): one
  # Alertmanager reads one secret, whichever mailbox it sends as.
  #
  # merge() takes maps as separate arguments; the audiences are a LIST of maps (one
  # per cluster), so `[...]...` expands that list into the argument list. The first
  # argument is the single map of own channels.
  destinations = merge(
    {
      for k, c in var.clusters : k => {
        cluster        = k
        audience       = ""
        key_vault_id   = data.azurerm_key_vault.cluster[k].id
        team_id        = var.teams_channels[c.teams_channel].team_id
        channel_id     = var.teams_channels[c.teams_channel].channel_id
        sender         = c.sender
        webhook_object = "teams-webhook-url"
        tags           = tomap(merge(local.tags, { cluster = k }))
      }
    },
    [
      for k, c in var.clusters : {
        for a, d in c.audiences : "${k}/${a}" => {
          cluster        = k
          audience       = a
          key_vault_id   = data.azurerm_key_vault.cluster[k].id
          team_id        = var.teams_channels[d.teams_channel].team_id
          channel_id     = var.teams_channels[d.teams_channel].channel_id
          sender         = d.sender
          webhook_object = "${a}-teams-webhook-url"
          tags           = tomap(merge(local.tags, { cluster = k, audience = a }))
        }
      }
    ]...
  )

  # Every mailbox the app must be able to send as, audiences included: exactly what
  # the Exchange scope covers. Sorted so the generated command line is stable.
  graph_senders = distinct(sort([for d in values(local.destinations) : d.sender]))

  # Caller allow-list per cluster: its static egress IP, when it pins one.
  allowed_caller_cidrs = {
    for k, ip in data.azurerm_public_ip.egress : k => ["${ip.ip_address}/32"]
  }
}

resource "azurerm_resource_group" "alerting" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# Each cluster's vault, by name. The vaults are owned by ../../org/keyvaults, so
# their IDs are resolved here, never restated.
data "azurerm_key_vault" "cluster" {
  for_each = var.clusters

  provider            = azurerm.shared
  name                = each.value.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

# The cluster's static egress IP, for clusters that pin one: the only address its
# Logic App triggers accept calls from. Read from the IP resource itself, so the
# allow-list follows the address instead of restating it.
data "azurerm_public_ip" "egress" {
  for_each = { for k, c in var.clusters : k => c.egress_public_ip if c.egress_public_ip != null }

  name                = each.value.name
  resource_group_name = each.value.resource_group_name
}
