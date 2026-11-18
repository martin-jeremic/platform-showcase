# Entra groups are the only identity objects in the access model. AKS binds the
# admins group to cluster-admin itself; every other binding is by object ID from
# platform/charts/rbac. No per-user object exists anywhere in the cluster, which is
# what makes off-boarding a single Entra change.
#
# Membership is deliberately NOT managed here. Coding it would mean an apply per
# joiner, no out-of-band emergency grant, and a plan that fights every manual
# change. Granting access is one command against a group that already exists:
#
#   az ad group member add --group grp-aks-org-prod-ns-<namespace> \
#     --member-id "$(az ad user show --id user@example.com --query id -o tsv)"
#
# prevent_destroy on every group: with membership held only in Entra, the group IS
# the access record, and destroying it silently discards the member list.

data "azuread_client_config" "current" {}

locals {
  group_prefix = "grp-${var.cluster_name}"

  # Entra descriptions are plain text -- no markdown, so no backticks.
  group_provenance = "Created by OpenTofu (infra/org/aks-prod); membership is managed by hand."

  # Entra rejects a group created by a service principal with no owner.
  group_owners = [data.azuread_client_config.current.object_id]
}

# Cluster-admin. Wired by AKS through admin_group_object_ids, so there is no
# RoleBinding to deploy for it -- and no way to express it in GitOps. Keep at least
# two members: with local accounts disabled there is no certificate break-glass.
resource "azuread_group" "admins" {
  display_name            = "${local.group_prefix}-admins"
  description             = "Full cluster-admin on ${var.cluster_name}. ${local.group_provenance}"
  security_enabled        = true
  assignable_to_role      = false
  prevent_duplicate_names = true
  owners                  = local.group_owners

  lifecycle {
    ignore_changes  = [members, owners]
    prevent_destroy = true
  }
}

# Cluster-wide read-only tier, created empty; its `view` binding comes from the
# rbac chart.
resource "azuread_group" "readers" {
  display_name            = "${local.group_prefix}-readers"
  description             = "Cluster-wide read-only on ${var.cluster_name}. ${local.group_provenance}"
  security_enabled        = true
  assignable_to_role      = false
  prevent_duplicate_names = true
  owners                  = local.group_owners

  lifecycle {
    ignore_changes  = [members, owners]
    prevent_destroy = true
  }
}

# One group per application namespace. Overlap is the point: someone who needs two
# namespaces joins two groups, with no code change. Per-user groups would need a
# binding set per combination; per-team groups cannot express someone who spans
# two teams. Removing an entry from var.namespaces is blocked by prevent_destroy:
# lift the guard, apply, restore it -- a decision made twice.
resource "azuread_group" "ns" {
  for_each = toset(var.namespaces)

  display_name            = "${local.group_prefix}-ns-${each.key}"
  description             = "Kubernetes edit in namespace ${each.key} on ${var.cluster_name}. ${local.group_provenance}"
  security_enabled        = true
  assignable_to_role      = false
  prevent_duplicate_names = true
  owners                  = local.group_owners

  lifecycle {
    ignore_changes  = [members, owners]
    prevent_destroy = true
  }
}
