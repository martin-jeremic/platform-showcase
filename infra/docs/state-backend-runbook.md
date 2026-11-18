# State backend runbook

Every stack keeps its state as one blob in a shared, hardened storage account,
created by [`tfstate-bootstrap/`](../tfstate-bootstrap/main.tf). Each blob is keyed
`<stack>.tfstate`. The account has versioning, 30-day soft delete for blobs and
containers, `prevent_destroy`, and a `CanNotDelete` lock.

## Adding a stack

No new infrastructure is needed. Copy the backend block, change `key`, and run
`tofu init`. To move an existing local state up, use `tofu init -migrate-state` and
answer **yes**.

## Locks

The `azurerm` backend takes a **blob lease** for every run, so two people (or a person
and a pipeline) cannot apply at once. An interrupted run (Ctrl+C, a crash, a closed
terminal) can leave the lease behind. The next command then fails with *state blob is
already locked*.

```bash
tofu force-unlock <LOCK_ID>   # the ID printed in the error
```

Run this **only** after you have confirmed that no other run or pipeline is in
progress. Stale locks almost always come from interrupting a slow apply or import:
let commands finish.

## Restoring a previous state version

Every write keeps the prior version.

```bash
az storage blob list --account-name sttfstateexample -c tfstate \
  --prefix <stack>.tfstate --include v -o table --auth-mode login
```

To restore a version, promote it in the portal (container, then blob, then
**Versions**), or download it and push it:

```bash
az storage blob download ... --version-id <id> -f /tmp/old.tfstate --auth-mode login
tofu state push /tmp/old.tfstate
rm /tmp/old.tfstate   # state holds secrets
```

**Versioning protects the state FILE, not the resources.** Restoring old state does
not undelete a resource that an apply removed. It only changes what OpenTofu believes
exists. Always check for `0 to destroy` before you apply.

## Terraform-written state and OpenTofu

Every snapshot records the version of the tool that wrote it. OpenTofu refuses a
snapshot whose recorded version is newer than the running binary, and Terraform's
version numbers are far ahead of OpenTofu's. So a blob last written by Terraform
blocks `tofu` with *state snapshot was created by Terraform vX, which is newer than
current*.

This is bookkeeping, not a format incompatibility: both tools use state format v4. The
fix, once per state key, before the first `tofu init` in that directory:

```bash
# 1. Take a blob version snapshot first, so this is trivially reversible.
terraform state pull > /tmp/state.json                 # Terraform can still read it
# 2. Edit "terraform_version" down to a version OpenTofu accepts (e.g. "1.9.0").
tofu state push -force /tmp/state.json                 # -force skips version/serial checks
rm /tmp/state.json
```

The `.gitignore` covers `*state*.json` as well as `*.tfstate`: a pulled state file
holds the same secrets but does not match the usual pattern.

## The bootstrap's own state

The first apply of the bootstrap has to use **local** state, because it creates the
account that would hold it. After that you have two options:

- leave it local and back the file up off the laptop (the product repository's
  choice); or
- add a backend block keyed `tfstate-bootstrap.tfstate` and run
  `tofu init -migrate-state` (the org repository's choice), so that losing one
  machine does not mean re-importing the state account by hand.

## Known gap

The account keeps shared keys enabled, because the backend reads state with an
account key unless every operator and pipeline uses `use_azuread_auth = true`.
Moving to Entra-only state access is listed in the README KNOWN-GAPS.
