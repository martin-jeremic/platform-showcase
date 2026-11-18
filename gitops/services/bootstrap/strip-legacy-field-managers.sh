#!/usr/bin/env bash
# ONE-TIME, per namespace, after Argo CD took it over from the old push CD (helm upgrade /
# kubectl apply). Removes the legacy field managers (`helm`, `kubectl-client-side-apply`) from
# every object that argocd-controller also manages, so argocd-controller becomes the SOLE owner
# of what it applies.
#
# WHY
# The ApplicationSet syncs with ServerSideApply=true. Server-side apply removes or reshapes a
# field only when no other manager still owns it. Objects the push CD created keep `helm` as a
# co-owner of every field the old chart set, so when a chart later drops or reshapes a field, the
# old one survives. Seen with a shared SPA chart: an env var the new chart had dropped stayed on
# four Deployments, and two others kept their old `value` next to the new `valueFrom`, so the API
# server rejected the Deployment. The new ConfigMap had already been applied, and Reloader
# restarted the pods into CreateContainerConfigError.
#
# Argo CD's built-in client-side-apply migration does not cover this: it converts only Update
# entries, and Helm 4 writes `helm/Apply` (server-side apply) entries.
#
# WHEN
# Once per namespace, after its first Argo sync on a takeover, and only when nothing else still
# writes there (otherwise the legacy managers come back). The script REFUSES to run while Helm
# release records exist in the namespace: the next `helm upgrade` would re-add `helm`.
#
# WHAT IT TOUCHES
# Only metadata.managedFields, through a JSON patch that `test`s each entry before removing it,
# so a patch fails atomically if the object changed in between. Entries are removed from the
# highest index down, so the lower indexes stay valid within one patch. No spec change, no pod
# restart. Fields only the legacy manager owned become unowned and stay as they are; fields
# argocd-controller co-owns become solely its own, so the next sync can prune or reshape them.
#
# USAGE (kubectl context = the cluster that hosts the namespace; needs jq)
#   bootstrap/strip-legacy-field-managers.sh <namespace>            # dry run: list what changes
#   bootstrap/strip-legacy-field-managers.sh <namespace> --apply    # patch
# Then sync the affected Applications: a sync that failed on these fields does not re-run on its
# own for the same revision once its retries are exhausted.

set -euo pipefail

NS="${1:?usage: $0 <namespace> [--apply]}"
MODE="${2:-}"
OWNER="argocd-controller"
LEGACY='["helm","kubectl-client-side-apply"]'

if [ -n "$(kubectl -n "$NS" get secret -l owner=helm -o name)" ]; then
  echo "ERROR: Helm release records exist in $NS; a helm upgrade would re-add the legacy manager." >&2
  echo "       Retire that release first (delete its sh.helm.release.v1.* Secrets; the objects stay)." >&2
  exit 1
fi

found=0
# Every namespaced kind that can be listed and patched (discovered, not hard-coded).
for kind in $(kubectl api-resources --namespaced --verbs=list,patch -o name); do
  json=$(kubectl -n "$NS" get "$kind" --show-managed-fields -o json 2>/dev/null) || continue

  # One line per object: "<name>\t<managers to drop>\t<json patch>".
  while IFS=$'\t' read -r name managers patch; do
    [ -n "$name" ] || continue
    found=$((found + 1))
    echo "$kind/$name: drop $managers"
    if [ "$MODE" = "--apply" ]; then
      kubectl -n "$NS" patch "$kind" "$name" --type=json -p "$patch" > /dev/null
    fi
  done < <(jq -r --arg owner "$OWNER" --argjson legacy "$LEGACY" '
    .items[]
    | select([.metadata.managedFields[]?.manager] | index($owner))
    | [ .metadata.managedFields | to_entries[] | select(.value.manager as $m | $legacy | index($m)) ] as $drop
    | select($drop | length > 0)
    | [ .metadata.name,
        ([ $drop[] | "\(.value.manager)/\(.value.operation)" ] | join(",")),
        ([ $drop | reverse[]
           | {op: "test",   path: "/metadata/managedFields/\(.key)/manager", value: .value.manager},
             {op: "remove", path: "/metadata/managedFields/\(.key)"} ] | tojson) ]
    | @tsv' <<< "$json")
done

if [ "$found" -eq 0 ]; then
  echo "Nothing to do in $NS."
elif [ "$MODE" = "--apply" ]; then
  echo "Patched $found object(s) in $NS."
else
  echo "Dry run: $found object(s) in $NS would be patched. Re-run with --apply."
fi
