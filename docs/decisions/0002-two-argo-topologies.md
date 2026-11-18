# 0002 · Hub-and-spoke for non-production, an island for product production

**Context.**
- **One Argo CD for everything.** It ran on an on-prem hub (a single node on office hardware) and reconciled every cluster, including the Azure ones.
- **A single point of failure.** That hub held cluster-admin credentials for every spoke.
- **A silent outage.** An expired personal access token once froze reconciliation of an entire repository for weeks, and no alert fired.

**Decision.** Split by network zone and criticality.
- **The hub** keeps the LAN clusters and the non-production Azure clusters. It manages them through cluster Secrets and a hub-only AppProject per cluster.
- **Product production** runs its own Argo CD in-cluster:
  1. OpenTofu installs it with `helm_release`.
  2. At sync wave 5, Argo adopts its own release, using a byte-identical release name and values.
  3. The OpenTofu resource is then frozen with `ignore_changes = all`, and Argo's own Application has `prune: false`.
- **Separate render targets.** The GitOps repositories render separate targets for the two Argo instances (`argocd/` and `argocd/overlays/prod/`), so neither ever generates the other's Applications.

**Consequences.**
- **Two Argo instances to upgrade.** They share one chart.
- **The hub sees nothing of production.** Production alerts route on their own.
- **The handoff is gated.** Adopt, freeze and enable automation are each a written gate with a rollback.

**Lessons.**
- **Release names must match exactly.** If they differ, Argo installs a second, parallel Argo CD.
- **Derive topology-spread selectors from the chart's own pod labels.** The pod label comes from `nameOverride`, not from the full name. A wrong selector matches zero pods, so the constraint is vacuously satisfied while looking enforced.
