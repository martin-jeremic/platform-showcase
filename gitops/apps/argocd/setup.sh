#!/usr/bin/env bash
# Wire this repository to the HUB Argo CD (namespace argocd-hub), the one that reconciles STAGE
# and DEMO. Idempotent: re-running updates the Secrets in place.
#
# PROD IS NOT DONE HERE. The prod application layer is reconciled by the Argo CD that runs on
# aks-product-a-prod itself (setup/prod/README.md). Registering prod as a hub spoke would put a
# second controller on the same namespace.
#
#   cp argocd/.env.example argocd/.env   # fill it in; .env is gitignored
#   bash argocd/setup.sh
#
# The credentials go to kubectl on stdin and are never written to a file in the repository.
set -euo pipefail

NS=argocd-hub
cd "$(dirname "$0")"

[ -f .env ] || { echo "Missing argocd/.env (copy .env.example and fill it in)." >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source ./.env
set +a
: "${ADO_TOKEN:?}" "${ACR_USER:?}" "${ACR_PASS:?}" "${HUB_CONTEXT:?}" "${STAGE_CONTEXT:?}" "${DEMO_CONTEXT:?}"

kc() { kubectl --context "$HUB_CONTEXT" -n "$NS" "$@"; }

# 1. This Git repository (the $values source). See setup/repo-git-product-a-gitops.yaml for why
#    forceHttpBasicAuth is required with Azure DevOps.
kc create secret generic repo-product-a-gitops \
  --from-literal=type=git \
  --from-literal=url=https://dev.azure.com/example-org/product-a/_git/product-a-gitops \
  --from-literal=username=azuredevops \
  --from-literal=password="$ADO_TOKEN" \
  --from-literal=forceHttpBasicAuth=true \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kc apply -f -

# 2. The OCI Helm registry (the service charts).
kc create secret generic repo-productacr-helm \
  --from-literal=type=helm \
  --from-literal=name=productacr \
  --from-literal=url=productacr.azurecr.io/helm \
  --from-literal=enableOCI=true \
  --from-literal=username="$ACR_USER" \
  --from-literal=password="$ACR_PASS" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kc apply -f -

# 3. The spokes: stage and demo only. The names must match destination.name in the appsets.
argocd cluster add "$STAGE_CONTEXT" --name product-a-stage --kube-context "$HUB_CONTEXT" -y
argocd cluster add "$DEMO_CONTEXT" --name aks-product-a-demo --kube-context "$HUB_CONTEXT" -y

# 4. Nothing else. The hub root Application is declared in gitops/platform and renders argocd/
#    (projects + appsets) from here. Applying those by hand would only create objects that drift
#    from Git, which is how the appsets once ended up hand-managed.
echo "Done. Check: argocd repo list; argocd cluster list"
