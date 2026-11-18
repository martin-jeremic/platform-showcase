# Custom OpenID client scopes and their protocol mappers.
#
# KNOWN INEXPRESSIBLE COMBINATION: display.on.consent.screen = true with an empty
# consent text. The provider derives the flag from whether consent_screen_text is
# non-empty. Import still plans clean, but the first UPDATE of such a scope flips
# the flag to false. Inert while no client requires consent; the exporter lists the
# affected scopes in the realm file.
resource "keycloak_openid_client_scope" "this" {
  for_each = var.client_scopes

  realm_id = keycloak_realm.this.id
  name     = each.key

  description                         = each.value.description
  consent_screen_text                 = each.value.consent_screen_text
  include_in_token_scope              = each.value.include_in_token_scope
  include_in_openid_provider_metadata = each.value.include_in_openid_provider_metadata
  gui_order                           = each.value.gui_order
}

locals {
  scope_protocol_mappers = merge([
    for scope, s in var.client_scopes : {
      for name, m in s.protocol_mappers : "${scope}/${name}" => merge(m, { scope = scope, name = name })
    }
  ]...)
}

# GENERIC mappers with the config map verbatim, not the typed mapper resources: the
# typed ones model only a subset of the keys Keycloak stores (lightweight.claim,
# introspection.token.claim, ...), so anything they omit is either dropped on apply
# or a permanent diff. Config values come from the per-object
# .../protocol-mappers/models endpoint, never from partial-export, which strips
# default-valued keys.
resource "keycloak_generic_protocol_mapper" "scope" {
  for_each = local.scope_protocol_mappers

  realm_id        = keycloak_realm.this.id
  client_scope_id = keycloak_openid_client_scope.this[each.value.scope].id

  name            = each.value.name
  protocol        = each.value.protocol
  protocol_mapper = each.value.protocol_mapper
  config          = each.value.config
}
