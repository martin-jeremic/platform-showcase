# 0006 · Secrets: Key Vault through the CSI driver, one workload identity per workload

**Context.**
- In a pull-based GitOps model, no pipeline can `--set` a secret at deploy time.
- Sealed or encrypted secrets in Git were rejected, because they add per-cluster key management and their own rotation story.

**Decision.**
- **Storage.** Secrets live in Azure Key Vault. Git holds only object names.
- **Delivery.** The CSI driver mounts the objects and syncs them into a Kubernetes Secret, which workloads consume as environment variables.
- **Identity.** Each workload authenticates with its own user-assigned identity, federated to its ServiceAccount. Its role assignment covers only the one vault it needs. It never uses the kubelet identity, which every pod on the node shares.

**Consequences and sharp edges.**
- **One missing object fails the whole mount.**
  - The pod sits in `ContainerCreating`, and the reason shows only in `kubectl describe`.
  - Optional features therefore gate their objects in the SecretProviderClass.
  - Seeding scripts run before the first promotion.
- **On-prem clusters need a label on the credentials Secret.**
  - Clusters without workload identity use a service principal. Its credentials Secret must carry `secrets-store.csi.k8s.io/used=true`.
  - Without the label, rotation fails silently. In practice this froze secrets for five days, with tens of thousands of failures per pod.
- **Rotation and config changes restart pods differently.**
  - Environment variables are read once at start. A rotated secret rolls pods through Reloader watching the synced Secret.
  - ConfigMap changes roll pods through a `checksum/config` annotation instead, because Reloader's restart stamp raced Argo's sync and was undone.
- **Three ways federation fails silently.** All three look like a missing role assignment:
  1. a subject that does not equal the pod's real ServiceAccount;
  2. client ID and principal ID swapped;
  3. a missing `azure.workload.identity/use` pod label.

**Known gap.** One production cluster still reads Key Vault through the kubelet identity for a few platform components; see [known gaps](../known-gaps.md).
