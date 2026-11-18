# 0013 · Adopt hand-installed Helm releases in place

**Context.** Several clusters ran platform components installed by hand with `helm install`. Reinstalling them under Argo CD would have meant downtime and lost state.

**Decision.** Argo CD adopts each release where it stands:
1. **Match exactly.** Use the same release name, namespace and chart.
2. **Prove nothing changes.** Run a server-side dry-run diff. It must show no change beyond known chart drift.
3. **Adopt in small batches.**
   - Add the descriptor.
   - Sync.
   - Delete the `sh.helm.release.v1.*` Secrets, so a later `helm upgrade` cannot fight Argo.
4. **Protect state first.** Annotate stateful volumes with `Prune=false` / `Delete=false` before the first sync.

**Lessons.**
- **Old field managers keep stale fields.**
  - Server-side apply keeps fields owned by the old `helm` or `kubectl-client-side-apply` field managers. An old `env` list survived next to the new `envFrom`, and the pod failed with `CreateContainerConfigError`.
  - A script lists the fields only Helm owns.
  - It removes the legacy managers with a JSON patch that runs `test` before each `remove` and works from the highest index down.
  - It refuses to run while Helm release Secrets still exist.
- **Keyed list entries get merged.**
  - Server-side apply merges keyed list entries that Helm owned. One volume name ended up with both a `secret` and a `csi` source.
  - Those DaemonSets are deleted once with `--cascade=orphan` and recreated by Argo, without restarting the pods.
- **Argo's built-in migration does not cover Helm.** `ClientSideApplyMigration` ignores `helm` / `Apply` manager entries.
