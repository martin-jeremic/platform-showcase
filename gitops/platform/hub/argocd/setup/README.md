# `argocd/setup/` -- one-time bootstrap of the hub, deliberately unmanaged

Nothing here is reconciled by Argo CD: the folder is excluded from
[`../kustomization.yaml`](../kustomization.yaml), and CI fails if any of it ever
renders through the root app. A repository credential managed by Argo could be
pruned by Argo -- and then nothing could read the repo that would restore it.

| File | What | Why it is not Argo-managed |
|---|---|---|
| `repo-creds-azure-devops.yaml` | repo-creds template: Entra workload identity for every ADO repo | Argo needs it before it can read anything |
| `repo-helm-oci.yaml` | the OCI Helm repository of the application charts | same |
| `cluster-template.yaml` | shape of a spoke registration (cold start only) | holds a bearer token once filled; the registry chart replaces it |
| `secrets-store-creds-template.yaml` | per-namespace CSI service-principal credential (on-prem spokes) | holds a client secret once filled |

None of these files contains a credential. The two templates are filled **in
memory** and piped to `kubectl`; filled copies are never written to disk or
committed.

## Order

1. Argo CD is running in `argocd-hub` (installed once by Helm; the `argocd`
   descriptor later adopts that release in place -- same release name, same
   `fullnameOverride`).
2. The hub's issuer is published (`oidc-issuer`) and the federated credential for
   `system:serviceaccount:argocd-hub:argocd-hub-repo-server` exists in Entra.
3. `kubectl -n argocd-hub replace -f repo-creds-azure-devops.yaml` and
   `repo-helm-oci.yaml`.
4. On each on-prem spoke, `secrets-store-creds` in every namespace that mounts Key
   Vault with the service-principal option, **before** that component's descriptor
   lands.
5. `kubectl -n argocd-hub apply -f ../root-application.yaml`.

Spokes are registered by the `argocd-cluster-registry` descriptor (tokens in Key
Vault). Its `name` must equal the cluster's directory under `platform/`.
