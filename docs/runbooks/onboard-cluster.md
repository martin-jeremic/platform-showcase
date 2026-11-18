# Onboard a cluster

## Register a spoke with the hub

1. **Mint a manager token on the spoke.** Create a dedicated ServiceAccount for Argo CD. Do not reuse a personal kubeconfig.
2. **Create the cluster Secret on the hub.** Fill a copy of `gitops/platform/hub/setup/cluster-secret.yaml.template`. The real file is never committed.
   - Use a non-loopback API URL.
   - Use the spoke's CA bundle.
   - Label it `argocd.argoproj.io/secret-type: cluster`.
3. **Add the cluster to the hub's GitOps.**
   1. Add an AppProject for the cluster, and an ApplicationSet whose generator reads `platform/<cluster>/*.yaml`.
   2. Add the new cluster to the cluster list in `component.sh`.
   3. Run `component.sh matrix` to refresh the README matrix.
4. **Choose the observability mode.**
   - **LAN spoke:** add `cluster-monitoring-agent`.
     - Copy the mTLS client bundle, issued by the hub's CA, into the spoke's Key Vault. A copy cannot follow renewal, so the certificate is long-lived on purpose.
     - Add a per-spoke trace tenant to `observability-ingest`.
   - **Internet-facing:** add the full `observability` stack with that cluster's own values.
5. **Add components one wave at a time.** For each component, run `component.sh add <cluster> <component>`, then commit the descriptor and its values file together. A component without a values file fails the render on purpose ([ADR-0004](../decisions/0004-gitops-values-are-the-single-source.md)).

## AKS prerequisites

- **Admissions enforcer.** The cluster's ApplicationSet must keep the admissions-enforcer `ignoreDifferences` carve-out together with `RespectIgnoreDifferences=true` ([ADR-0008](../decisions/0008-server-side-apply-and-narrow-ignores.md)).
- **Access.** Use Entra-only access. Fill the namespace group object IDs into `platform/values/<cluster>/rbac.yaml` from `tofu output`. The chart refuses to render while any GUID is empty.

## Taking over an existing platform

If the cluster already runs hand-installed releases, follow the adopt-in-place procedure ([ADR-0013](../decisions/0013-adopt-in-place.md)). Do not add descriptors that would install a second copy. This matters most for DaemonSet-based components such as the CSI driver: a second copy registers a second driver on the same node socket.
