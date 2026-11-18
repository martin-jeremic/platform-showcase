#!/usr/bin/env bash
# check-platform.sh -- lint, render and gate every chart in this repository.
#
# For every <chart>/ with a Chart.yaml:
#   1. `helm dependency build` when the chart declares dependencies (subcharts are
#      NOT committed: charts/ is gitignored, Chart.lock pins the exact digests);
#   2. `helm lint` + `helm template` once per ci/*.yaml values file;
#   3. tools/render-gates.py on each render: no PersistentVolume / hostPath PV, no
#      route on `/`, no route on every listener, no literal password, no
#      REPLACE_WITH_, no untagged or :latest image, no `example-internal`, and the
#      production floor (priority + limits) per workload.
# Then the refusal tests: renders that MUST fail, each with the error text that
# proves it failed for the right reason. A guard that silently stops refusing is
# as broken as one that refuses everything.
# Then, if the binaries are on PATH: promtool (rule syntax + unit tests), the
# dashboard checks, and the log-contract comparison.
#
# Usage, from the repository root (platform/charts/):
#   tools/check-platform.sh            # everything
#   tools/check-platform.sh traefik    # one chart
#
# Needs: helm (3.17+ or 4), python3. Optional: promtool, lokitool (see
# tools/check-log-rules.sh for fetching lokitool at the rendered Loki version).
set -euo pipefail

cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# A python that actually runs (on Windows `python3` can be the Store stub).
PY=${PYTHON:-}
if [ -z "$PY" ]; then
  for c in python3 python; do
    if "$c" -c 'import sys' >/dev/null 2>&1; then PY=$c; break; fi
  done
fi
[ -n "$PY" ] || { echo "FAIL: no working python3/python on PATH"; exit 1; }

# Dependencies are fetched, never committed (charts/ is gitignored). Skip the
# network when charts/ already holds every pinned version; otherwise register the
# repositories Chart.yaml names (helm dependency build refuses unknown repos) and
# build from Chart.lock.
deps_ready() { # <chart>
  local name ver
  while read -r name ver; do
    [ -f "$1/charts/$name-$ver.tgz" ] || return 1
  done < <(awk '/^dependencies:/{d=1} d && /- name:/{n=$3} d && /version:/{gsub(/"/,"",$2); print n, $2}' "$1/Chart.yaml")
}
build_deps() { # <chart>
  deps_ready "$1" && return 0
  local i=0 url
  for url in $(awk '/repository:/{gsub(/"/,"",$2); print $2}' "$1/Chart.yaml" | sort -u); do
    i=$((i + 1))
    helm repo add "$(basename "$1")-dep$i" "$url" --force-update >/dev/null
  done
  helm dependency build "$1" >/dev/null
}

# The ServiceMonitor/PrometheusRule CRDs exist on every cluster these charts serve
# (observability installs them). Tell helm, or the CRD-gated templates render
# nothing here and the gates check less than Argo applies.
APIS=(--api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor)

fail=0
note() { echo "==> $*"; }

charts=()
if [ $# -gt 0 ]; then
  charts=("$@")
else
  for c in */Chart.yaml; do charts+=("${c%/Chart.yaml}"); done
fi

# ---------------------------------------------------------------------------
# 1-3. lint, render, gate
# ---------------------------------------------------------------------------
for chart in "${charts[@]}"; do
  note "$chart"
  if grep -q '^dependencies:' "$chart/Chart.yaml"; then
    build_deps "$chart" || { echo "FAIL $chart: helm dependency build"; fail=1; continue; }
  fi
  shopt -s nullglob
  ci=("$chart"/ci/*.yaml)
  shopt -u nullglob
  [ ${#ci[@]} -gt 0 ] || { echo "FAIL $chart: no ci/*.yaml -- every chart needs test values that render"; fail=1; continue; }
  # The namespace each chart is rendered into, where it matters to a guard.
  ns=$chart
  case "$chart" in
    oidc-issuer) ns=default ;;
    observability|observability-ingest|observability-log-rules|grafana-sso-gateway|cluster-monitoring-agent) ns=observability ;;
  esac
  for v in "${ci[@]}"; do
    out="$WORK/$chart-$(basename "$v" .yaml).yaml"
    if ! helm lint "$chart" -f "$v" --namespace "$ns" >"$WORK/lint.txt" 2>&1; then
      cat "$WORK/lint.txt"; echo "FAIL $chart: helm lint -f $v"; fail=1; continue
    fi
    if ! helm template "$chart" "$chart" -n "$ns" "${APIS[@]}" -f "$v" >"$out" 2>"$WORK/err.txt"; then
      cat "$WORK/err.txt"; echo "FAIL $chart: helm template -f $v"; fail=1; continue
    fi
    "$PY" tools/render-gates.py "$chart" "$out" || fail=1
    echo "   ok  $v ($(grep -c '^kind:' "$out") objects)"
  done
done

# ---------------------------------------------------------------------------
# 4. refusal tests -- each render MUST fail, with this text in the error
# ---------------------------------------------------------------------------
refuse() { # <chart> <namespace> <expected error substring> <helm args...>
  local chart=$1 ns=$2 want=$3; shift 3
  [ -d "$chart" ] || return 0
  if helm template "$chart" "$chart" -n "$ns" "${APIS[@]}" "$@" >/dev/null 2>"$WORK/refuse.txt"; then
    echo "FAIL refusal $chart: rendered, but must refuse ($want)"; fail=1
  elif ! grep -qF -- "$want" "$WORK/refuse.txt"; then
    echo "FAIL refusal $chart: failed for another reason:"; cat "$WORK/refuse.txt"; fail=1
  else
    echo "   ok  $chart refuses: $want"
  fi
}
if [ $# -eq 0 ]; then
  note "refusal tests"
  # rbac: an empty Entra group object ID would grant nothing, silently.
  refuse rbac kube-system "entraGroupId must be an Entra group object ID"
  # cluster-admin: values.schema.json catches it before the template's own guard.
  refuse rbac kube-system "clusterRole must be one of" -f rbac/ci/test-values.yaml \
    --set 'clusterBindings[0].clusterRole=cluster-admin'
  # traefik: the TLS floor is only real in Traefik's own namespace.
  refuse traefik traefik "defaultTLSResourcesNamespace must be set" -f traefik/ci/test-values.yaml \
    --set traefik.providers.kubernetesCRD.defaultTLSResourcesNamespace=
  refuse traefik traefik "gateway.listeners.websecure.hostname is required" \
    --set 'redirect.hostnames[0]=x.example.com'
  # keycloak: KC_HOSTNAME and the route both derive from config.host.
  refuse keycloak keycloak "config.host is required" -f keycloak/ci/test-values.yaml --set config.host=
  refuse keycloak keycloak "appVersion is NOT a valid image tag" -f keycloak/ci/test-values.yaml --set image.digest=
  # rabbitmq: no guest, no Secret from values.
  refuse rabbitmq rabbitmq "must not be guest" -f rabbitmq/ci/test-values.yaml --set auth.username=guest
  refuse rabbitmq rabbitmq "never renders a password Secret from values" --set azureKeyVault.enabled=false
  # elasticsearch: authentication cannot be switched off by accident.
  refuse elasticsearch infrastructure "renders an unauthenticated Elasticsearch" -f elasticsearch/ci/test-values.yaml \
    --set security.enabled=false
  # mongo: a backup with nowhere to go must not deploy and quietly do nothing.
  refuse mongo mongo "backup.azure.accountName is empty" -f mongo/ci/test-values.yaml --set backup.azure.accountName=
  # argocd-cluster-registry: the hub cannot reach its own loopback.
  refuse argocd-cluster-registry argocd-hub "is loopback" -f argocd-cluster-registry/ci/test-values.yaml \
    --set 'clusters[0].server=https://127.0.0.1:16443'
  # oidc-issuer: the backend Service lives in `default`.
  refuse oidc-issuer kube-system "must be installed into namespace default" -f oidc-issuer/ci/test-values.yaml
  # headlamp: no cluster-admin through a browser session.
  printf 'groupRbac:\n  bindings:\n    - group: ops\n      clusterRole: cluster-admin\n' >"$WORK/headlamp-ca.yaml"
  refuse headlamp headlamp "cluster-admin is not grantable through Headlamp" -f headlamp/ci/test-values.yaml -f "$WORK/headlamp-ca.yaml"
  # observability: one cluster identity, ruler wired to the sidecar folder, and
  # the identity wiring of the Alertmanager Key Vault mount.
  refuse observability observability "logs and metrics would name this cluster differently" \
    -f observability/ci/island-values.yaml --set alloyPipeline.cluster=other
  refuse observability observability "no log alert rule would load" \
    -f observability/ci/island-values.yaml --set loki.loki.rulerConfig.storage.local.directory=/var/loki/rules
  refuse observability observability "has no azure.workload.identity/use" \
    -f observability/ci/island-values.yaml --set 'kubePromStack.alertmanager.alertmanagerSpec.podMetadata.labels=null'
  refuse observability observability "searchNamespace" \
    -f observability/ci/island-values.yaml --set kubePromStack.grafana.sidecar.dashboards.searchNamespace=ALL
  refuse observability observability "kubePromStack.grafana.persistence.storageClassName is required" \
    -f observability/ci/hub-values.yaml --set kubePromStack.grafana.persistence.storageClassName=
  # cluster-monitoring-agent: the volume behind /etc/alloy/tls must match the source.
  # (the ci values minus their restated CSI volume: keyVault over the base Secret volume)
  sed '/^    volumes:/,$d' cluster-monitoring-agent/ci/test-values.yaml >"$WORK/agent-novol.yaml"
  refuse cluster-monitoring-agent observability "is not a CSI volume" -f "$WORK/agent-novol.yaml"
  # observability-log-rules: a new rules file must be shipped, not forgotten.
  refuse observability-log-rules observability "tenant is required"
fi

# ---------------------------------------------------------------------------
# 5. rules, dashboards, log contract
# ---------------------------------------------------------------------------
if [ $# -eq 0 ]; then
  note "dashboards"
  "$PY" tools/validate-dashboards.py observability/dashboards || fail=1
  "$PY" tools/check-dashboard-threshold.py \
    observability-log-rules/log-rules/ingest-rate.yaml observability/dashboards/Product/ingest-rate.json || fail=1

  note "log contract: observability's Alloy vs observability-ingest"
  printf 'alloyPipeline:\n  parseLogContract: true\n' >"$WORK/contract.yaml"
  helm template observability observability -n observability "${APIS[@]}" \
    -f observability/ci/hub-values.yaml -f "$WORK/contract.yaml" >"$WORK/contract-obs.yaml"
  helm template observability-ingest observability-ingest -n observability \
    -f observability-ingest/ci/test-values.yaml >"$WORK/contract-ingest.yaml"
  "$PY" tools/compare-log-contract.py "$WORK/contract-obs.yaml" "$WORK/contract-ingest.yaml" hub-dev || fail=1

  note "alert rules (promtool)"
  if command -v promtool >/dev/null 2>&1; then
    promtool check rules observability/rules/*.yaml || fail=1
    promtool test rules observability/rules/tests/*.yaml || fail=1
  else
    echo "SKIP promtool not on PATH -- CI runs it from the rendered Prometheus image"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo; echo "PLATFORM CHECKS FAILED"; exit 1
fi
echo; echo "ALL PLATFORM CHECKS PASS"
