# ---------------------------------------------------------------------------
# Custom authentication flows
# ---------------------------------------------------------------------------

# Built-in flows are never declared. The realm's flow BINDINGS live in
# `settings` (browser_flow, ...), so a custom flow that is actually bound is
# visible from the realm block, and a flow declared here but bound nowhere is an
# orphan: fully configured, executed never.
#
# `priority` is explicit on every execution and subflow: the provider neither
# computes nor defaults it, and 0 would reorder the flow. Live priorities are
# often non-contiguous (Keycloak leaves gaps when the console adds and removes
# steps) and are reproduced as-is, because renumbering changes evaluation order.
#
# FRESH CREATION of a multi-level flow can need a second apply: the provider
# appends executions in creation order and only then sets priorities. Adoption
# by import is unaffected.

resource "keycloak_authentication_flow" "this" {
  for_each = var.authentication_flows

  realm_id    = keycloak_realm.this.id
  alias       = each.key
  description = each.value.description
  provider_id = each.value.provider_id
}

locals {
  subflows_l1 = {
    for k, s in var.authentication_subflows : k => s if contains(keys(var.authentication_flows), s.parent_flow)
  }
  subflows_l2 = {
    for k, s in var.authentication_subflows : k => s if !contains(keys(var.authentication_flows), s.parent_flow)
  }
}

# Import id: {{realm}}/{{parent flow alias}}/{{the subflow's own FLOW id}}, not the
# id of the execution that represents it inside the parent.
resource "keycloak_authentication_subflow" "l1" {
  for_each = local.subflows_l1

  realm_id          = keycloak_realm.this.id
  parent_flow_alias = keycloak_authentication_flow.this[each.value.parent_flow].alias

  alias         = each.key
  description   = each.value.description
  provider_id   = each.value.provider_id
  authenticator = each.value.authenticator
  requirement   = each.value.requirement
  priority      = each.value.priority
}

resource "keycloak_authentication_subflow" "l2" {
  for_each = local.subflows_l2

  realm_id          = keycloak_realm.this.id
  parent_flow_alias = keycloak_authentication_subflow.l1[each.value.parent_flow].alias

  alias         = each.key
  description   = each.value.description
  provider_id   = each.value.provider_id
  authenticator = each.value.authenticator
  requirement   = each.value.requirement
  priority      = each.value.priority
}

# Import id: {{realm}}/{{parent flow alias}}/{{execution id}}. Execution ids are
# NOT in a realm export; the exporter reads them from
# GET /authentication/flows/{alias}/executions.
resource "keycloak_authentication_execution" "this" {
  for_each = var.authentication_executions

  realm_id          = keycloak_realm.this.id
  parent_flow_alias = each.value.parent_flow
  authenticator     = each.value.authenticator
  requirement       = each.value.requirement
  priority          = each.value.priority

  depends_on = [
    keycloak_authentication_flow.this,
    keycloak_authentication_subflow.l1,
    keycloak_authentication_subflow.l2,
  ]
}

# Import id: {{realm}}/{{execution id}}/{{config id}}. Config aliases are
# namespaced per realm, not per flow, so a copied flow carries prefixed aliases.
resource "keycloak_authentication_execution_config" "this" {
  for_each = { for k, e in var.authentication_executions : k => e.config if e.config != null }

  realm_id     = keycloak_realm.this.id
  execution_id = keycloak_authentication_execution.this[each.key].id
  alias        = each.value.alias
  config       = each.value.config
}
