# TEMPORARY -- carries prod's state across two module changes. Delete this file
# after prod's first successful apply past them; `tofu plan` must then print
# "No changes".
#
# 1. Two Grafana groups used to be instances of the module's tenant-group for_each.
#    Prod does not want them, but they hold memberships, so they are FORGOTTEN,
#    never destroyed. A `removed` block cannot target a single for_each INSTANCE,
#    so each is first MOVED to an address nothing declares, and that address is
#    then removed as a whole.
# 2. Service-account grants became authoritative keycloak_user_roles in the module.
#    The import brings each account's live role set into state so the plan shows
#    every grant added or revoked as an explicit role_ids change. On a realm that
#    does not exist yet (first apply creates it) delete the import: there is
#    nothing to import.

moved {
  from = module.realm.keycloak_group.this["grafana-product-a-admin"]
  to   = keycloak_group.retired_grafana["grafana-product-a-admin"]
}

moved {
  from = module.realm.keycloak_group.this["grafana-product-a-viewer"]
  to   = keycloak_group.retired_grafana["grafana-product-a-viewer"]
}

removed {
  from = keycloak_group.retired_grafana

  lifecycle {
    destroy = false
  }
}

import {
  for_each = toset(keys(module.realm.service_account_user_ids))
  to       = module.realm.keycloak_user_roles.service_account[each.key]
  id       = "${var.realm_name}/${module.realm.service_account_user_ids[each.key]}"
}
