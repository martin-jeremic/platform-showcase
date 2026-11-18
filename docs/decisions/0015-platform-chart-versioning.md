# 0015 · Platform charts are versioned by per-chart Git tags

**Context.** Platform charts were read from `main`. Any merged chart change reached every cluster at the next sync, and there was no way to roll a change out to one cluster first.

**Decision.**
- **A tag makes a version available.** Each tag is named `<chart>-<Chart.yaml version>`.
- **A descriptor bump makes it live.** Each cluster's descriptor pins `chartRevision` to a tag; bumping it deploys that version to that cluster.
- **CI keeps the two in step:**
  - **On a PR** that changes a chart without bumping its version, CI adds a patch bump and commits it back to the PR branch.
  - **On `main`**, CI cuts any missing tags.
  - **Descriptors** are bumped only to tags that already exist on the remote.
- **Upstream dependencies** are pinned per chart in `Chart.lock`.

**Consequences.**
- **Rollback** is a descriptor revert.
- **Tags are immutable only by convention.** CI never moves a tag.
- **Auto-promotion merges the two steps.** For the single cluster that uses it, "available" and "live" become the same thing. That cluster accepts this trade-off.
