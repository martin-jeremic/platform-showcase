# Keycloak consolidation: three generations, one module, an exporter

## Where it started

Keycloak configuration went through three generations.

1. **Shell scripts** against the admin CLI and API, authenticated as the master-realm
   superuser. They were not idempotent. A bootstrap script had a production admin
   password committed in plain text. On Windows they read IDs with a trailing `\r`
   (a CRLF-emitting `jq`).
2. **Per-product stacks with near-duplicate module trees.** There were four trees per
   environment pair, each with hand-copied import UUIDs. Each stack held dev and prod
   in **one** state file. The realm object was a data source, so token lifespans,
   brute-force settings and flow bindings were unmanaged and differed per instance.
   Toggles and `check` blocks stood in for what should have been plain
   per-environment data. A half-finished apply left objects in state that collided
   with hand-made ones.
3. **One generic module, one root per Keycloak instance, an exporter.** This is
   [`org/keycloak`](../org/keycloak/). The product realms kept their own hand-written
   module ([`product-a/keycloak`](../product-a/keycloak/)), which predates it and
   models one product's realm shape exactly.

## The design

- **Environment is data, not code.** Each realm is one `module` block of typed objects
  (clients, scopes, roles, groups, flows, brokers), with no toggles and no `-target`.
  Promotion means copying a block and changing the URLs.
- **One root and one state per instance.** A module change rolls out to dev first.
  A root can only reach its own instance.
- **Generated, not hand-copied.** [`kc_export.py`](../scripts/keycloak/kc_export.py)
  reads a live realm and writes the realm file plus temporary import blocks. It is
  idempotent: a second run produces no diff, which makes it a drift audit that is
  independent of `tofu plan`.
- **Adoption is faithful.** The first plan shows imports and re-asserting creates. The
  only in-place changes are documented, one-time write-backs:
  - deletion protection;
  - `use_refresh_tokens` where the attribute is absent live;
  - `extra_config` keys the import Read leaves empty.

  The exporter prints the expected counts. **Fix the code, never the realm.**
- **Findings are fixed after adoption, one reviewed change at a time.** The exporter
  writes `SECURITY` markers where they sit: realm-management roles in the default
  roles, brute force off, public clients without PKCE, wildcard redirects.
- **The credential is never managed by the stack.**
  [`kc_bootstrap.py`](../scripts/keycloak/kc_bootstrap.py) creates it. If OpenTofu
  owned it, a bad apply could rotate the secret it runs with.

## Provider lessons the module absorbs

- **The redirect-URI guard reads state, not config.** A service-account client with a
  live `["/*"]` cannot be written, and leaving the argument null does not help. The
  module declares both fields **empty** when the flow that uses them is off. The first
  update then clears the inert live values.
- **Scope attachments are authoritative and cannot be imported.** They plan as
  creates whose lists must equal the live lists, built-ins included.
- **Data lookups use the realm NAME.** A lookup through `keycloak_realm.this.id`
  defers the read to apply whenever the realm has pending changes. That left role
  container IDs unknown, and every grant on `realm-management` planned as a
  replacement.
- **Broker secrets come back as a mask.** The module defaults to the mask and pins the
  field with `ignore_changes`, so the stack can never rotate or clobber a broker
  secret by accident.
- **Composite roles are split into two resources** so a composite can reference flat
  roles. Flat roles declare `composite_roles = []` explicitly. Composites the module
  cannot express stop the exporter.
- **Realm `terraform_deletion_protection`** plus `prevent_destroy`, because removing
  the module call removes the lifecycle block with it.

## Moving state across refactors

When objects moved between the module and a root, `moved` and `removed` blocks
re-addressed or **forgot** them. Nothing was destroyed. A `removed` block cannot
target a single `for_each` instance, so the instance is first moved to an address
nothing declares, and that address is then removed
([`product-a/keycloak/prod/migrate.tf`](../product-a/keycloak/prod/migrate.tf)). The
additive per-role grants were replaced by authoritative `keycloak_user_roles`
(`exhaustive = true`), which made a hand-granted admin role visible to plan for the
first time.
