# Teams delivery: Alertmanager msteamsv2 -> Logic App -> Teams channel post.
#
# Alertmanager's msteamsv2 receiver POSTs {"type":"message","attachments":[{
# contentType:"application/vnd.microsoft.card.adaptive", content:{AdaptiveCard}}]}
# to whatever URL its webhook_url_file holds. The Teams-side "Workflows -> Send
# webhook alerts to a channel" template accepts that body, but it is a Power
# Automate flow created by hand in the Teams client: its definition lives in no
# repo and its URL has to be copied into the vault by a person. That was the
# original design. This Logic App accepts the same body and does the same post, and
# it is code: the trigger URL goes from callback_url straight into Key Vault.
#
# One Logic App per destination, so each has its own URL in its own vault and one
# can be revoked or IP-restricted without touching the others -- the same reasoning
# as one Graph secret per cluster. All of them share ONE Teams API connection, so
# there is one OAuth sign-in for the whole stack.
#
# The run reports the REAL outcome. The workflow answers synchronously: 200 only
# after every card was posted, 502 when a post failed. The Teams template answers
# 202 on receipt instead, so a broken post looks delivered to Alertmanager. Here a
# failure shows up as a msteamsv2 notify error and in
# alertmanager_notifications_failed_total{integration="msteamsv2"}, and
# Alertmanager retries it (it retries every 5xx). Logic Apps Consumption holds a
# synchronous caller for at most 120 s, which is why the post is capped at 90 s.

data "azurerm_managed_api" "teams" {
  name     = "teams"
  location = azurerm_resource_group.alerting.location
}

# Created unauthenticated. Someone opens it once in the portal (Edit API connection
# -> Authorize) and signs in as the service account the cards are posted with; that
# account must be a member of every team in var.teams_channels. There is no
# headless alternative: the Teams connector only takes a delegated OAuth sign-in,
# and Graph has no app-only permission to post channel messages.
resource "azurerm_api_connection" "teams" {
  name                = "con-alerting-teams"
  resource_group_name = azurerm_resource_group.alerting.name
  managed_api_id      = data.azurerm_managed_api.teams.id
  display_name        = "${var.app_display_name} (Teams)"
  tags                = local.tags
}

# Warns on every plan until the connection is authorised, and again if its token is
# ever revoked (password reset, account disabled, consent removed). Until then
# every Teams post fails with 502.
check "teams_connection_authorized" {
  data "azapi_resource" "teams_connection" {
    type                   = "Microsoft.Web/connections@2016-06-01"
    resource_id            = azurerm_api_connection.teams.id
    response_export_values = ["properties.statuses"]
  }

  assert {
    condition     = try(data.azapi_resource.teams_connection.output.properties.statuses[0].status, "") == "Connected"
    error_message = "Teams API connection ${azurerm_api_connection.teams.name} is not authorised (status: ${try(data.azapi_resource.teams_connection.output.properties.statuses[0].status, "unknown")}). Portal -> ${azurerm_resource_group.alerting.name} -> ${azurerm_api_connection.teams.name} -> Edit API connection -> Authorize, signed in as the alerting service account. Until then every Teams post returns 502."
  }
}

resource "azurerm_logic_app_workflow" "teams" {
  for_each = local.destinations

  name                = "logic-alerting-${replace(each.key, "/", "-")}"
  resource_group_name = azurerm_resource_group.alerting.name
  location            = azurerm_resource_group.alerting.location

  # The managed-connection binding every ApiConnection action resolves through.
  workflow_parameters = {
    "$connections" = jsonencode({ type = "Object", defaultValue = {} })
  }
  parameters = {
    "$connections" = jsonencode({
      teams = {
        connectionId   = azurerm_api_connection.teams.id
        connectionName = azurerm_api_connection.teams.name
        id             = data.azurerm_managed_api.teams.id
      }
    })
  }

  # The trigger URL carries its own SAS signature, so holding the URL is the whole
  # authorisation. For a cluster with a pinned egress IP, also refuse callers from
  # anywhere else. The portal's "Run trigger" comes from elsewhere and is refused
  # too: test from inside the cluster.
  dynamic "access_control" {
    for_each = contains(keys(local.allowed_caller_cidrs), each.value.cluster) ? [local.allowed_caller_cidrs[each.value.cluster]] : []
    content {
      trigger {
        allowed_caller_ip_address_range = access_control.value
      }
    }
  }

  tags = each.value.tags
}

resource "azurerm_logic_app_trigger_http_request" "alertmanager" {
  for_each = local.destinations

  name         = "alertmanager"
  logic_app_id = azurerm_logic_app_workflow.teams[each.key].id
  method       = "POST"

  # Documents the msteamsv2 body; the actions below rely on `attachments`.
  schema = jsonencode({
    type = "object"
    properties = {
      type = { type = "string" }
      attachments = {
        type = "array"
        items = {
          type = "object"
          properties = {
            contentType = { type = "string" }
            content     = { type = "object" }
          }
          required = ["contentType", "content"]
        }
      }
    }
    required = ["attachments"]
  })
}

# One Teams post per attachment (msteamsv2 sends exactly one). A body without
# `attachments` fails the Foreach, so it ends in a 502 rather than a silent 200.
#
# "Post card in a chat or channel" (operationId PostCardToConversation) of the
# Teams managed API, posting as Flow bot. Path, poster and location values come from
# the connector's swagger: GET .../locations/<region>/managedApis/teams?export=true.
resource "azurerm_logic_app_action_custom" "post_cards" {
  for_each = local.destinations

  name         = "For_each_card"
  logic_app_id = azurerm_logic_app_workflow.teams[each.key].id

  body = jsonencode({
    type     = "Foreach"
    foreach  = "@triggerBody()?['attachments']"
    runAfter = {}
    actions = {
      Post_card = {
        type     = "ApiConnection"
        runAfter = {}
        inputs = {
          host = {
            connection = { name = "@parameters('$connections')['teams']['connectionId']" }
          }
          method = "post"
          path   = "/v1.0/teams/conversation/adaptivecard/poster/@{encodeURIComponent('Flow bot')}/location/@{encodeURIComponent('Channel')}"
          body = {
            recipient = {
              groupId   = each.value.team_id
              channelId = each.value.channel_id
            }
            messageBody = "@{string(items('For_each_card')?['content'])}"
          }
          # Bounded so the Response below always goes out inside the 120 s a
          # synchronous caller is held. Alertmanager retries a 502 itself.
          retryPolicy = { type = "fixed", count = 2, interval = "PT10S" }
        }
        limit = { timeout = "PT90S" }
      }
    }
  })
}

resource "azurerm_logic_app_action_custom" "respond_delivered" {
  for_each = local.destinations

  name         = "Respond_delivered"
  logic_app_id = azurerm_logic_app_workflow.teams[each.key].id

  body = jsonencode({
    type     = "Response"
    kind     = "Http"
    runAfter = { For_each_card = ["Succeeded"] }
    inputs = {
      statusCode = 200
      body       = { status = "delivered", run = "@{workflow()['run']['name']}" }
    }
  })

  depends_on = [azurerm_logic_app_action_custom.post_cards]
}

# The run name lands in the Alertmanager log (msteamsv2 includes the response body
# in its error): that is the run to open in the Logic App's run history.
resource "azurerm_logic_app_action_custom" "respond_failed" {
  for_each = local.destinations

  name         = "Respond_failed"
  logic_app_id = azurerm_logic_app_workflow.teams[each.key].id

  body = jsonencode({
    type     = "Response"
    kind     = "Http"
    runAfter = { For_each_card = ["Failed", "TimedOut", "Skipped"] }
    inputs = {
      statusCode = 502
      body       = { status = "teams post failed", run = "@{workflow()['run']['name']}", logicApp = "@{workflow()['name']}" }
    }
  })

  depends_on = [azurerm_logic_app_action_custom.post_cards]
}
