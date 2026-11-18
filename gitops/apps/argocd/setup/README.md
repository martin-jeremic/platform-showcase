# Hub wiring (argocd-hub on hub-dev): stage + demo

One-time registration of what the hub Argo CD needs before it can reconcile this repository. After that, the hub root Application (declared in `gitops/platform`) manages everything from Git.

> Prod is not here: see [`prod/README.md`](prod/README.md).

Nothing in this folder is listed in [`../kustomization.yaml`](../kustomization.yaml). The files are **templates** with `REPLACE_ME` placeholders, never filled in Git. Keeping them out of the render target means a prune can never delete the credential Argo needs in order to read the repository that tells it what to do. That failure cannot heal itself, because recovering requires reading the repository.

| File | Registers |
|---|---|
| [`repo-git-product-a-gitops.yaml`](repo-git-product-a-gitops.yaml) | This repository (`type: git`, `forceHttpBasicAuth: "true"`; see the file for the 302-instead-of-401 reason) |
| [`repo-helm-acr.yaml`](repo-helm-acr.yaml) | `productacr.azurecr.io/helm` (`type: helm`, `enableOCI: "true"`) |
| [`cluster-product-a-stage.yaml`](cluster-product-a-stage.yaml) | The stage spoke (the declarative alternative to `argocd cluster add`); demo is registered the same way as `aks-product-a-demo` |

Fastest path: `cp ../.env.example ../.env`, fill it in, `bash ../setup.sh`.

## Verify

```bash
argocd repo list        # both repositories: Successful
argocd cluster list     # product-a-stage + aks-product-a-demo
kubectl -n argocd-hub get applicationsets,applications -l app.kubernetes.io/part-of=product-a
```

A service appears only after its first promotion writes `apps/<svc>/<env>/release.yaml`. Until then "no Application" is the correct state.
