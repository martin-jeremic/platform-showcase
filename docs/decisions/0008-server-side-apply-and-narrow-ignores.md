# 0008 · Server-side apply, server-side diff, and narrow `ignoreDifferences`

**Context.**
- Client-side diff reported CRD defaults and fields written by other controllers as drift.
- Turning off self-heal would silence that noise, but it would also hide real drift.

**Decision.**
- **Sync with server-side apply.**
- **Compare with server-side diff.**
  - Enable it with the `argocd.argoproj.io/compare-options: ServerSideDiff=true` annotation.
  - Do not put it in `syncOptions`. There it is silently ignored, which looks like it worked.
- **Ignore only fields other controllers own:**
  - **Reloader's `last-reloaded-from` annotation.** If self-heal reverted it, the workload would restart a second time and stay OutOfSync permanently.
  - **The AKS admissions enforcer's webhook exclusions.**
    - It appends two `namespaceSelector` exclusions to every webhook configuration.
    - `matchExpressions` is an atomic list, so server-side diff cannot absorb the change.
    - A `jqPathExpressions` entry drops exactly the entries with those two keys. Real edits to the chart's own selectors still show as drift.
- **Keep `RespectIgnoreDifferences=true`.** It is load-bearing. Without it, a sync applies the full manifest anyway, and Argo and Azure fight over the field indefinitely.
- **Spell out defaulted fields in Gateway API routes** (`group`, `kind`, `weight`). The API server stores them. Leave them out and the route stays OutOfSync forever.

**Consequences.** Helm-managed objects that Argo takes over keep their old `helm` field managers. See [0013](0013-adopt-in-place.md).
