# 0014 · Keycloak as code

**Context.**
- **Imperative scripts drifted.** Realms were built with scripts, and the realms drifted apart: one environment lacked clients that another had.
- **Three generations of hand-written OpenTofu existed side by side.** Their problems:
  - module trees duplicated five times;
  - state files spanning dev and prod;
  - realms read as data sources instead of managed;
  - feature toggles.

**Decision.**
- **One generic realm module.** All inputs are typed objects with `optional()` fields.
- **One root per Keycloak instance.**
- **A read-only exporter** (Python, standard library only).
  - It reads a live realm through the Admin API.
  - It renders the realm's module call plus a config-driven `import {}` block for every existing object.
  - Re-running it on an unchanged realm produces no Git diff, so it doubles as a drift audit.
- **Adoption by import.** Each realm is adopted by import, and the first plan must contain zero destroys.
- **Provisioner credentials stay outside OpenTofu.** A script bootstraps them; tofu never manages them.

**Provider lessons** (Keycloak provider 5.x):
- **Declare `composite_roles = []`.** The attribute is Optional+Computed. If it is undeclared, every plan shows a no-op change forever.
- **Use separate resources for default and optional client scopes.** They are authoritative, and the realm read never returns them.
- **Switch to exhaustive role grants carefully.**
  - `keycloak_user_roles` with `exhaustive = true` replaces the additive per-role resources.
  - Forget the old resources with `removed { lifecycle { destroy = false } }`, so live grants are not revoked.
- **To forget one `for_each` instance, move it first.** A `removed` block cannot target a single instance. Move it to an undeclared address, then forget that address.
- **Mask identity-provider secrets.** Set them to a mask and add `ignore_changes`, so tofu never writes them back.
- **Compute the redirect-URI guard in the module.** The provider rejects redirect URIs on clients without a browser flow, but only at apply time, so the plan never warns.
- **Keep descriptions under 255 characters.** Longer ones fail on an MSSQL-backed Keycloak.
