# 0004 · Environment values live only in GitOps; a missing values file is an error

**Context.**
- **Values lived in two places.** Platform values were split between chart repositories (`values-<cluster>.yaml`) and GitOps, combined with `ignoreMissingValueFiles: true`.
- **A rename failed silently.** A half-finished rename made one cluster render base values only, while Argo still reported Synced and Healthy.
- **The fallback did real damage.** On one spoke it pruned a hostPath PersistentVolume, which stuck in `Terminating` and blocked syncs for about a month.
- **Application charts had the same problem.** Chart defaults quietly supplied keys that each environment was supposed to state itself.

**Decision.**
- **One source.** Every environment value lives in the GitOps repository and is layered last.
- **No silent fallback.** `ignoreMissingValueFiles` is off everywhere, so a missing file fails the render.
- **gitops/apps: a perturbation check.**
  - For every environment, the PR check pulls the pinned chart from the registry and renders it twice: once with the environment's values, once with every leaf of the `config` block altered.
  - A ConfigMap key whose value does not change is owned by the chart default, not by the environment, and the check fails.
  - Exceptions need a written reason.

**Consequences.**
- **Explicit environment files.** Every key appears in each environment's file.
- **Registry access.** The PR pipeline needs it, plus a cache.
- **Further rules the check enforces:**
  - key sets match across environments;
  - no Base64-encoded JSON;
  - no empty values;
  - pinned pairs share a version and digest.
