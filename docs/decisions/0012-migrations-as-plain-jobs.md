# 0012 · Database migrations run as a plain Job named by digest

**Context.**
- Helm hooks and Argo hooks behave differently. Under self-heal, both re-run or vanish in surprising ways.
- Migrating when the application starts runs the migration once per replica.

**Decision.**
- **A separate Job chart.** The database schema has its own chart: a plain `Job`, not a hook.
- **Same image, verb argument.** The Job runs the API image's entrypoint with a verb argument (`--verify`, `--migrate` or `--seed`). The runtime image has no shell, so the Job passes arguments only, never a `command`.
- **A name that encodes the run.** Each Job is named `<release>-migrate-<first 12 hex of the digest>-<run nonce>`, so a new image or a re-run gets a new, immutable Job.
- **No automatic retries.**
  - `backoffLimit: 0`: a failed migration is investigated, not repeated.
  - No TTL, so the evidence stays.
- **No self-heal for the schema Application.** The environment's `release.yaml` turns self-heal off; otherwise a completed-and-deleted Job would be re-run.
- **Paired, but separate.** The API and its schema chart share a version and digest, a pinned pair checked in CI. They are still separate Applications, with separately named synced Secrets, because two Applications owning one Secret would prune each other.
- **Push-based environments run the Job first.** They deploy it with `--wait --wait-for-jobs`, before the application.

**Consequences.** Schema-before-code is guaranteed only where the pipeline orders it. Everywhere else, migrations must be expand/contract, enforced by a migration lint.
