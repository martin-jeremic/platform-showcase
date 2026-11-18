# The COMPLETE direct role set of every app service account.
#
# keycloak_user_roles with exhaustive = true is authoritative: it lists every realm
# and client role the account holds directly and revokes anything else. That is the
# point. The additive per-role resources it replaced could only ever ADD a grant, so
# a role granted by hand in the console was invisible to `tofu plan` and survived
# every apply -- which is how one environment's admin-API service account came to
# hold superadmin and platform_admin without any config saying so.
#
# terraform-provisioner is deliberately absent: it is tofu's own credential, owned
# by bootstrap-provisioner.sh, and a wrong list here would lock tofu out of the realm.

# Keycloak names the default-role composite "default-roles-<realm, lower-cased>"
# and maps it onto every user, service accounts included. A wrong name fails here,
# at plan time.
data "keycloak_role" "default_roles" {
  realm_id = local.realm_id
  name     = "default-roles-${lower(var.realm_name)}"
}

data "keycloak_openid_client" "realm_management" {
  count = length(concat(var.api_realm_management_roles, var.admin_api_realm_management_roles)) > 0 ? 1 : 0

  realm_id  = local.realm_id
  client_id = "realm-management"
}

data "keycloak_role" "api_realm_management" {
  for_each = toset(var.api_realm_management_roles)

  realm_id  = local.realm_id
  client_id = data.keycloak_openid_client.realm_management[0].id
  name      = each.value
}

data "keycloak_role" "admin_api_realm_management" {
  for_each = toset(var.admin_api_realm_management_roles)

  realm_id  = local.realm_id
  client_id = data.keycloak_openid_client.realm_management[0].id
  name      = each.value
}

# Auto-created with authorization services; declared so the exhaustive set keeps it.
data "keycloak_role" "token_client_uma_protection" {
  realm_id  = local.realm_id
  client_id = keycloak_openid_client.token_client.id
  name      = "uma_protection"
}

locals {
  service_account_roles = {
    api = {
      user_id  = keycloak_openid_client.api.service_account_user_id
      role_ids = concat([data.keycloak_role.default_roles.id], [for r in data.keycloak_role.api_realm_management : r.id])
    }
    mcp_data = {
      user_id  = keycloak_openid_client.mcp_data.service_account_user_id
      role_ids = [data.keycloak_role.default_roles.id]
    }
    module = {
      user_id  = keycloak_openid_client.module.service_account_user_id
      role_ids = [data.keycloak_role.default_roles.id, keycloak_role.realm["prompt_governance_service"].id]
    }
    token_client = {
      user_id  = keycloak_openid_client.token_client.service_account_user_id
      role_ids = [data.keycloak_role.default_roles.id, data.keycloak_role.token_client_uma_protection.id]
    }
    admin_api = {
      user_id  = keycloak_openid_client.admin_api.service_account_user_id
      role_ids = concat([data.keycloak_role.default_roles.id], [for r in data.keycloak_role.admin_api_realm_management : r.id])
    }
  }
}

resource "keycloak_user_roles" "service_account" {
  for_each = local.service_account_roles

  realm_id   = local.realm_id
  user_id    = each.value.user_id
  role_ids   = each.value.role_ids
  exhaustive = true
}

# The additive per-role resources this file replaced. FORGOTTEN, not destroyed:
# destroying them would revoke live grants that keycloak_user_roles above declares
# again. Remove these blocks once every root that ever applied them has applied
# past this change.
removed {
  from = keycloak_openid_client_service_account_realm_role.module_governance

  lifecycle {
    destroy = false
  }
}

removed {
  from = keycloak_openid_client_service_account_role.api_realm_management

  lifecycle {
    destroy = false
  }
}
