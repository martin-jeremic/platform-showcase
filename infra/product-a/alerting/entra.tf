# The identity Alertmanager sends mail as: Graph POST /users/{sender}/sendMail,
# client-credentials flow, one client secret per cluster.
#
# NO Graph permission is granted here, deliberately: no required_resource_access
# block, no azuread_app_role_assignment. Mail.Send is granted in Exchange Online by
# RBAC for Applications (exchange/Set-AlertingSenderScope.ps1), scoped to the sender
# mailboxes (local.graph_senders). The two systems are ADDITIVE: an Entra-granted
# Mail.Send would be unscoped and let this app send as ANY mailbox in the tenant,
# whatever the Exchange scope says. Keeping the Entra side empty makes the setup
# fail closed -- until the Exchange assignment exists, the app can send as nobody.
#
# The missing required_resource_access is also why the portal offers no "Grant
# admin consent" button for this app. Do not add one: that button is how the
# scoping gets undone by accident. The Exchange script refuses to run while the
# service principal holds any Entra app-role assignment.
#
# Consequence for the applier: creating an app registration needs Application
# Administrator, Cloud Application Administrator or Application Developer.
# Privileged Role Administrator is NOT needed, because nothing is consented.

data "azuread_client_config" "current" {}

resource "azuread_application" "alerting" {
  display_name            = var.app_display_name
  description             = "Alertmanager notifications (Graph sendMail). Mail.Send is granted in Exchange Online RBAC for Applications, scoped to ${join(", ", local.graph_senders)}. ${local.provenance}"
  sign_in_audience        = "AzureADMyOrg"
  prevent_duplicate_names = true

  # Entra rejects an app created by a service principal with no owner. Ignored
  # after creation so ownership can be handed over without drift.
  owners = [data.azuread_client_config.current.object_id]

  lifecycle {
    ignore_changes = [owners]
  }
}

resource "azuread_service_principal" "alerting" {
  client_id   = azuread_application.alerting.client_id
  description = "Alertmanager notifications. ${local.provenance}"
  owners      = [data.azuread_client_config.current.object_id]

  lifecycle {
    ignore_changes = [owners]
  }
}

# ---- one client secret per cluster, rotated on apply ---------------------------
#
# Rotation happens only when someone runs `tofu apply` after the rotation date;
# there is no scheduler. secret_rotation_days is when an apply replaces the secret;
# secret_lifetime is when Entra stops accepting it. The gap is the slack for an
# apply that runs late, and check.graph_secret_expiry warns on every plan once a
# secret is within 60 days of expiry.
#
# Why replacing the secret does not drop notifications: create_before_destroy
# creates the new secret, keyvault.tf writes it as a new version of the vault
# object in the same apply, and only then is the old one deleted. Alertmanager keeps
# its cached Graph token (about 1 h) and re-reads client_secret_file on every
# request; when the CSI driver rewrites the file (its rotation poll), the client
# rebuilds its token source with the new secret. A refresh that falls inside those
# minutes fails, and Alertmanager retries the notification.

resource "time_rotating" "graph_secret" {
  for_each = var.clusters

  rotation_days = var.secret_rotation_days

  lifecycle {
    # Both durations measured from the same fixed instant, so this is decidable
    # at plan time without knowing when the apply will run.
    precondition {
      condition     = timecmp(timeadd("2000-01-01T00:00:00Z", var.secret_lifetime), timeadd("2000-01-01T00:00:00Z", "${var.secret_rotation_days * 24}h")) > 0
      error_message = "secret_lifetime must be longer than secret_rotation_days, otherwise each secret expires before the apply that replaces it is due."
    }
  }
}

resource "azuread_application_password" "graph" {
  for_each = var.clusters

  application_id = azuread_application.alerting.id

  # The date makes the current secret recognisable in the portal next to the one
  # it is about to replace.
  display_name = "${each.key} ${formatdate("YYYY-MM-DD", time_rotating.graph_secret[each.key].rfc3339)}"
  end_date     = timeadd(time_rotating.graph_secret[each.key].rfc3339, var.secret_lifetime)

  rotate_when_changed = {
    rotation = time_rotating.graph_secret[each.key].id
  }

  lifecycle {
    create_before_destroy = true
  }
}

check "graph_secret_expiry" {
  assert {
    condition = alltrue([
      for p in values(azuread_application_password.graph) :
      timecmp(p.end_date, timeadd(plantimestamp(), "1440h")) > 0
    ])
    error_message = "A Graph client secret expires within 60 days: ${join(", ", [for k, p in azuread_application_password.graph : "${k} on ${p.end_date}" if timecmp(p.end_date, timeadd(plantimestamp(), "1440h")) <= 0])}. Run `tofu apply` to rotate it; mail from that cluster stops when it expires."
  }
}
