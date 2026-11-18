# Prod bootstrap (aks-product-a-prod)

Prod is an island: the Argo CD that runs on `aks-product-a-prod` (namespace `argocd`) reconciles both the platform layer and this application layer. Nothing here touches the hub.

## Once

1. **Repository credentials, on the prod Argo.** A repository Secret is per URL and per namespace, so the hub's Secrets do not serve this Argo CD. Apply the same two shapes as [`../repo-git-product-a-gitops.yaml`](../repo-git-product-a-gitops.yaml) and [`../repo-helm-acr.yaml`](../repo-helm-acr.yaml), with `namespace: argocd`.
2. **The root app:** `kubectl -n argocd apply -f argocd/root-application-prod.yaml`. It renders `argocd/overlays/prod` (one AppProject, one ApplicationSet). No workload appears until the first `Production` approval writes `apps/<svc>/prod/release.yaml`.
3. **Key Vault objects first.** The Secrets Store CSI driver fails the WHOLE mount if one declared object is missing. The pod sits in `ContainerCreating` with a generic message while Argo still shows Synced. Seed every `<svc>--<key>` object in `kv-product-a-prod` before the first sync.

## Launch gates

| Gate | Check |
|---|---|
| Platform layer healthy | Gateway `websecure` listener `Programmed`, cert-manager certificate `Ready`, identity provider realm reachable |
| Workload identity | Each app's federated credential subject is `system:serviceaccount:product-a:<svc>`; the identity holds Key Vault Secrets User on `kv-product-a-prod` only |
| Database roles | Created by the database operations runbook before the first migration Job |
| Vault seeded | `az keyvault secret list --vault-name kv-product-a-prod` lists every object the charts declare |
| First sync | Manual: `argocd app sync <svc>-prod`, the migration Job chart first |

## Syncs are manual until re-armed

The prod appset has no `automated` block. A generated Application shows OutOfSync and deploys nothing until somebody syncs it, unless its `release.yaml` opts in (`syncPolicy.automated`). Re-arming the whole environment is one commit: change the `{{- else }}` branch of the `templatePatch` in [`../../overlays/prod/appset-product-a-prod.yaml`](../../overlays/prod/appset-product-a-prod.yaml).

Manual sync does **not** protect against deletion: removing a `prod/release.yaml` cascade-deletes that service's workloads through the Application finalizer.
