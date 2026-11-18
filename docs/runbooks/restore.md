# Restore data

Every restore creates something **new** next to the original. Nothing restores in place. Point the consumer at the restored copy only after you have verified it.

## PostgreSQL Flexible Server

| Need | Mechanism | Retention |
|---|---|---|
| Undo a mistake in the last days | Point-in-time restore, built into the service | 7 days (non-prod), 35 days (prod) |
| Recover an older state | Long-term backup in a Data Protection backup vault (weekly, tiered) | Weeks / months / years |

1. **Restore to a new server name.**
   - PITR: `az postgres flexible-server restore --source-server … --restore-time …`.
   - Long-term backup: restore from the vault. It produces dump files in a storage container, which you then load into a fresh server.
2. **Recreate the roles.** Roles are not part of a database dump. Run `infra/scripts/postgres/create-app-roles.sql` with the passwords passed as psql variables.
3. **Repoint the application.** Update the connection-string object in Key Vault, then let the rotation path restart the pods.
4. **Expect no per-tenant granularity.** Every tenant schema lives in one database, so a restore brings back every tenant. To recover one tenant, restore to a new server and copy that schema back.

If a vaulted backup instance shows `ProtectionStopped`, an earlier instance was soft-deleted and then undeleted, and the weekly backup is silently not running. Resume protection explicitly, then re-import it into OpenTofu. The stack has a postcondition on `protection_state`, so this is caught at the next plan.

## Blob storage

The account has versioning, change feed and soft delete. Point-in-time restore keeps a window one day shorter than soft delete, because the restore window must be strictly shorter than the soft-delete window.

```bash
az storage blob restore --account-name <acct> --time-to-restore <UTC> --blob-range <container>/<prefix> <container>/<prefix>~
```

## MongoDB (self-hosted)

1. **Find the dump.** A CronJob dumps the database to a separate GRS storage account. Its identity can create blobs but cannot delete them; lifecycle rules do all pruning.
2. **Download the archive** with Entra auth (`az storage blob download --auth-mode login`).
3. **Restore it** with `mongorestore --archive --gzip` into a fresh instance or namespace.

## Key Vault object

```bash
az keyvault secret list-versions --vault-name <kv> --name <obj>        # an older version is still there
az keyvault secret recover --vault-name <kv> --name <obj>             # soft-deleted within 90 days
```

Purge protection is on, so a deleted object can always be recovered within the retention window.

## OpenTofu state

See [infra/docs/state-backend-runbook.md](../../infra/docs/state-backend-runbook.md). Every write keeps the previous blob as a version, so a corrupted or truncated state file is a restore, not a rebuild.
