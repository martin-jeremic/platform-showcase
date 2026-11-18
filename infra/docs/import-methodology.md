# Import methodology: adopting hand-built Azure resources

Context: the organisation's production estate was built in the portal before any IaC
existed. These rules came out of the SQL, registry, Key Vault and Keycloak adoptions.
Each one was added because something went wrong without it.

## The rules

1. **Import, don't rebuild.** Nothing live is renamed, recreated or destroyed. If a
   live name breaks the repo's naming convention, the live name wins, because a
   rename is destroy-and-create (new FQDN, downtime, data migration). Record the
   deviation next to the variable instead. Examples: `rg-sql-org`, and portal-generated
   firewall rule names kept verbatim.
2. **One workload, one stack.** Each stack is a flat folder with the same file set. The
   backend block is copied, and only `key` changes.
3. **Inventory before HCL.** Read every live value with read-only `az` commands and map
   each one field by field to provider arguments. The live values become the
   variable defaults, so a fresh checkout with no tfvars plans clean against reality.
   The one drift finding in the repository came from breaking this rule: an empty
   `firewall_rules` default would have destroyed live rules.
4. **Config-driven `import {}` blocks in a temporary `imports.tf`.**
   - Build the import IDs from variables through `locals`. Resource attributes do not
     exist at plan time.
   - Import collections with `for_each`, keyed by the live name.
   - Run `tofu plan -generate-config-out=generated.tf` once as a cross-check. It
     surfaces Optional+Computed fields and provider renames that the hand-written
     config missed. Fold in what is real, then delete the generated file.
   - Example: [`org/registry/imports.tf.example`](../org/registry/imports.tf.example).
5. **The no-op gate.** The import plan must read exactly *N to import, 0 to add, 0 to
   change, 0 to destroy*. After the apply, with `imports.tf` deleted, the next plan must
   read *No changes*.
   - Any other diff means the config is wrong. Fix the config. Never let an apply
     change a live resource to make it agree.
   - A *replace* in an import plan means a config name does not match a live name.
6. **Write-only fields get a required-but-inert variable.** Azure never returns
   passwords, so any value in config plans as a change that would *reset the live
   credential*. Keep the argument (the provider requires it), hold it inert with
   `ignore_changes`, and rotate deliberately at go-live. Example:
   [`org/mssql`](../org/mssql/main.tf).
7. **Tags and locks go in a second commit.** Tags, management locks and any hardening
   stay out of the import pass, so its plan stays a pure no-op. That no-op is the one
   signal that proves the import is correct. A real mistake hidden in a list of
   expected tag diffs is easy to miss.
   - Exception: `prevent_destroy`. It lives only in state, produces no diff, and goes
     in from the start.
8. **Guard data in both directions.** `prevent_destroy` blocks OpenTofu, including
   ForceNew renames. A `CanNotDelete` lock blocks the portal and the CLI. They fail in
   different directions, so anything that holds data gets both.
   - Creating a lock needs Owner or User Access Administrator.
9. **The data plane stays out.** Vault secrets, registry images and blob contents
   belong to applications and pipelines. Importing them would put secret material
   into state.
10. **Pin the subscription on every command.** The backend block names no
    subscription, so everything resolves against the CLI default, which is shared
    mutable state. It caused trouble twice: once a misleading `ResourceGroupNotFound`
    at init, once a silently switched default. Use `ARM_SUBSCRIPTION_ID` for tofu and
    `--subscription` for `az`, not `az account set`.
11. **Close the loop.**
    - Delete `imports.tf`.
    - Compare `tofu state list` with `az resource list -g <rg>`. The counts may differ
      only for documented reasons (system databases, children that are not listed).
    - Check that `tofu plan -destroy` **fails** on the guards.
    - Write execution notes for anything that went differently. Rules 6 and 10 came
      from those notes.

## Keycloak variant

The same rules apply to the Keycloak adoption, with two additions:

- **Generate, don't hand-copy.** The exporter writes the import blocks, so nobody types
  a UUID.
- **Expect re-asserting creates.** Some resources cannot be imported (scope
  attachments, realm events). They plan as creates whose values equal the live values,
  so each apply is a server-side no-op. The exporter prints the expected counts per
  resource type, and the plan must match them. See
  [`keycloak-consolidation.md`](keycloak-consolidation.md).
