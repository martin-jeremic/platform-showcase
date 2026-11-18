# One-time wiring (hub `argocd-hub`)

Nothing here is managed by Argo: it is outside [`../kustomization.yaml`](../kustomization.yaml).

| Step | What | File |
|---|---|---|
| 1 | Repository registration (no credential; inherits the workload-identity repo-creds template) | [`repo-git-services-gitops.yaml`](repo-git-services-gitops.yaml), applied with `kubectl replace` |
| 2 | OCI chart registry `orgacr.azurecr.io/helm` (`type: helm`, `enableOCI: "true"`) | shared with the platform charts, registered in `gitops/platform` |
| 3 | `aks-org-prod` registered as a cluster named exactly `aks-org-prod` | `gitops/platform` (`argocd-cluster-registry`) |
| 4 | Per business namespace on the hub: `secrets-store-creds` with the `used=true` label | [`secret-secrets-store-creds.yaml`](secret-secrets-store-creds.yaml) |
| 5 | Seed Key Vault objects before the first promotion of a backend | [`../../bootstrap/populate-kv.sh`](../../bootstrap/populate-kv.sh) |
| 6 | Root app | `kubectl -n argocd-hub apply -f ../root-application.yaml` |

Verify: `argocd repo list`, then `kubectl -n argocd-hub get applicationset services -o jsonpath='{.status.conditions}'`. Read the ApplicationSet conditions rather than the root app's health: a missing project shows up only there.
