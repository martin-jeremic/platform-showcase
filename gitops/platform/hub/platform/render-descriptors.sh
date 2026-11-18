#!/usr/bin/env bash
# render-descriptors.sh <charts-repo> [--worktree] -- render every descriptor the
# way Argo CD renders it: the chart AT ITS PINNED TAG, layered with
# values.yaml + platform/values/<cluster>/<component>.yaml, under the descriptor's
# release name and namespace.
#
# Argo can only report a broken render as a ComparisonError after the merge; this
# moves the failure before it. Every `fail` guard in the charts (missing cluster
# identity, a Key Vault mount without its identity wiring, a loopback spoke URL...)
# is evaluated against the real per-cluster values here.
#
#   <charts-repo>  a clone of the charts repo WITH TAGS (CI: fetchDepth 0, fetchTags)
#   --worktree     render the charts as they are on disk instead of at the pinned
#                  tag -- for a local run before the tags exist.
#
# Needs helm and git.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHARTS="${1:?usage: render-descriptors.sh <charts-repo> [--worktree]}"
MODE="${2:-tag}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APIS=(--api-versions monitoring.coreos.com/v1 --api-versions monitoring.coreos.com/v1/ServiceMonitor)

field() { awk -v k="$2" '$1==k":"{v=$2; gsub(/"/,"",v); print v; exit}' "$1"; }

fail=0; n=0
for desc in "$HERE"/*/*.yaml; do
  cluster=$(basename "$(dirname "$desc")")
  [ "$cluster" = values ] && continue
  comp=$(basename "$desc" .yaml)
  path=$(field "$desc" chartPath); tag=$(field "$desc" chartRevision)
  rel=$(field "$desc" releaseName); ns=$(field "$desc" namespace)
  vals="$HERE/values/$cluster/$comp.yaml"
  dir="$WORK/$cluster-$comp"; mkdir -p "$dir"
  if [ "$MODE" = --worktree ]; then
    cp -r "$CHARTS/$path" "$dir/"
  else
    git -C "$CHARTS" rev-parse -q --verify "refs/tags/$tag" >/dev/null \
      || { echo "FAIL $cluster/$comp: tag $tag does not exist in the charts repo -- Argo would report ComparisonError"; fail=1; continue; }
    git -C "$CHARTS" archive "$tag" "$path" | tar -x -C "$dir"
  fi
  if grep -q '^dependencies:' "$dir/$path/Chart.yaml" && [ ! -d "$dir/$path/charts" ]; then
    helm dependency build "$dir/$path" >/dev/null || { echo "FAIL $cluster/$comp: helm dependency build"; fail=1; continue; }
  fi
  if helm template "$rel" "$dir/$path" -n "$ns" "${APIS[@]}" \
       -f "$dir/$path/values.yaml" -f "$vals" >"$dir/render.yaml" 2>"$dir/err.txt"; then
    echo "ok    $cluster/$comp ($tag, $(grep -c '^kind:' "$dir/render.yaml") objects)"
    n=$((n + 1))
  else
    echo "FAIL  $cluster/$comp ($tag):"; sed 's/^/      /' "$dir/err.txt"; fail=1
  fi
done
echo "$n descriptors rendered"
exit "$fail"
