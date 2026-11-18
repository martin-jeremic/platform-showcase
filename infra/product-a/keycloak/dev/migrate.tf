# TEMPORARY -- carries dev's state across the switch to authoritative service-account
# roles. Delete this file after the first successful apply; `tofu plan` must then
# print "No changes".
#
# The imports bring each account's LIVE role set into state, so the plan shows any
# difference as an explicit role_ids change instead of hiding it inside a create.
# The per-role resources they replace are forgotten by `removed` blocks in the
# module. The keys come from a module output built from locals only, so they are
# known at plan time without a dependency cycle through the resources being imported.

import {
  for_each = toset(keys(module.realm.service_account_user_ids))
  to       = module.realm.keycloak_user_roles.service_account[each.key]
  id       = "${var.realm_name}/${module.realm.service_account_user_ids[each.key]}"
}
