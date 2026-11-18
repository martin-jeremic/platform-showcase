#!/usr/bin/env sh
# component.sh -- manage which platform component runs on the island cluster.
# (The island's copy of the hub repo's helper: same model, one cluster, and the
# `prune: false` field that the argocd descriptor must never lose.)
#
# A component runs on a cluster IFF platform/<cluster>/<component>.yaml exists.
# Every descriptor has a values file in a DISJOINT tree:
#   platform/<cluster>/<component>.yaml         the DESCRIPTOR (chart, pinned tag, wave)
#   platform/values/<cluster>/<component>.yaml  the VALUES (what the chart is given)
# Both are required: the appsets are multi-source and do NOT set
# ignoreMissingValueFiles, so a missing values file is a render failure, not a
# silent fall-back to chart defaults.
#
# Usage:
#   sh platform/component.sh add      <cluster> <component>
#   sh platform/component.sh remove   <cluster> <component>
#   sh platform/component.sh list     [cluster]
#   sh platform/component.sh bump     <cluster> <component> <tag>
#   sh platform/component.sh matrix   # print + refresh the README matrix
#   sh platform/component.sh validate
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
CATALOG="$HERE/catalog.yaml"
README="$HERE/../README.md"   # no matrix markers there: a single cluster needs none
CLUSTERS="aks-product-a-prod"
HUB=""   # the island has no hub: one cluster, its own in-cluster Argo CD

die() { echo "error: $*" >&2; exit 1; }

# All component names defined in the catalog (2-space indent, key only).
catalog_components() {
  awk '/^components:/{f=1;next}
       f&&/^  [A-Za-z0-9_-]+:[[:space:]]*$/{gsub(/[: ]/,"");print}' "$CATALOG"
}

# One field of one component: catalog_field <component> <field>
#
# Matches only fields at the component's OWN indent level (4 spaces), and stops at
# the first hit. Both guards are load-bearing: a `notes: >-` folded block is
# indented deeper and its continuation lines are free prose, so a note that happens
# to begin a line with "prune: false ..." was once returned as a second value for
# the `prune` field. That produced a multi-line result, the `= "false"` test
# failed, and the argocd descriptor came out WITHOUT its guard -- Argo CD would
# have been allowed to prune itself.
catalog_field() {
  awk -v c="$1" -v k="$2" '
    $0 ~ "^  "c":[[:space:]]*$" {inblk=1; next}
    inblk && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {inblk=0}
    inblk && /^    [A-Za-z0-9_-]+:/ {
      line=$0; sub(/^[[:space:]]+/,"",line)
      key=line; sub(/:.*/,"",key)
      if (key==k) {
        val=line; sub(/^[^:]*:[[:space:]]*/,"",val); sub(/[[:space:]]+#.*$/,"",val); gsub(/^"|"$/,"",val)
        print val; exit
      }
    }' "$CATALOG"
}

# One top-level field of a descriptor: desc_field <file> <field>
desc_field() { awk -v k="$2" '$1==k":"{v=$2; gsub(/"/,"",v); print v; exit}' "$1"; }

known_component() { catalog_components | grep -qx "$1"; }
known_cluster()   { echo "$CLUSTERS" | tr ' ' '\n' | grep -qx "$1"; }

cmd_add() {
  [ $# -eq 2 ] || die "usage: add <cluster> <component>"
  cluster="$1"; comp="$2"
  known_cluster "$cluster" || die "unknown cluster '$cluster' (known: $CLUSTERS)"
  known_component "$comp"  || die "unknown component '$comp' (see catalog.yaml)"
  cp="$(catalog_field "$comp" chartPath)"; cv="$(catalog_field "$comp" chartRevision)"
  rel="$(catalog_field "$comp" releaseName)"; ns="$(catalog_field "$comp" namespace)"
  wave="$(catalog_field "$comp" syncWave)"; scope="$(catalog_field "$comp" scope)"
  [ -n "$cp" ] && [ -n "$cv" ] && [ -n "$rel" ] && [ -n "$ns" ] && [ -n "$wave" ] \
    || die "catalog incomplete for '$comp'"
  case "$scope" in
    placeholder) echo "warning: '$comp' is a placeholder component" >&2 ;;
  esac
  out="$HERE/$cluster/$comp.yaml"
  [ -f "$out" ] && die "already present: $out"
  mkdir -p "$HERE/$cluster"
  {
    echo "# Platform descriptor -- its PRESENCE deploys '$comp' to '$cluster'."
    echo "# Scaffolded by component.sh from catalog.yaml; safe to hand-edit."
    echo "chartPath:     $cp"
    echo "chartRevision: $cv   # pinned git tag -- the pin that makes rollback possible"
    echo "releaseName:   $rel"
    echo "namespace:     $ns"
    echo "syncWave:      \"$wave\""
    if [ "$(catalog_field "$comp" prune)" = "false" ]; then
      echo "# prune: false -- this component manages the controller performing the sync."
      echo "# Pruning your own controller mid-sync bricks the cluster."
      echo "prune:         false"
    fi
  } > "$out"
  echo "created $out"
  vout="$HERE/values/$cluster/$comp.yaml"
  if [ ! -f "$vout" ]; then
    mkdir -p "$HERE/values/$cluster"
    {
      echo "# Cluster values for '$comp' on '$cluster', layered after the chart's values.yaml."
      echo "# Must exist even if empty: the appset does not set ignoreMissingValueFiles."
      echo "{}"
    } > "$vout"
    echo "created $vout"
  fi
  refresh_readme
}

cmd_remove() {
  [ $# -eq 2 ] || die "usage: remove <cluster> <component>"
  f="$HERE/$1/$2.yaml"
  [ -f "$f" ] || die "not present: $f"
  echo "removing $f -- '$2' and its resources are PRUNED from '$1' on the next sync" >&2
  rm "$f"; echo "removed $f"
  rm -f "$HERE/values/$1/$2.yaml"
  refresh_readme
}

cmd_bump() {
  [ $# -eq 3 ] || die "usage: bump <cluster> <component> <tag>"
  f="$HERE/$1/$2.yaml"
  [ -f "$f" ] || die "not present: $f (add it first)"
  case "$3" in "$(desc_field "$f" chartPath)"-*) ;; *) die "tag '$3' is not <chartPath>-<version> for $f" ;; esac
  old="$(desc_field "$f" chartRevision)"
  # Rewrite the one line, preserving every comment and the rest of the file.
  sed "s|^chartRevision:.*|chartRevision: $3   # pinned git tag -- the pin that makes rollback possible|" "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
  echo "$2 on $1: chartRevision $old -> $3"
  echo "reminder: the tag must already exist on the charts repo's origin"
}

cmd_list() {
  for cl in $CLUSTERS; do
    [ $# -ge 1 ] && [ "$1" != "$cl" ] && continue
    echo "== $cl =="
    found=0
    for f in "$HERE/$cl"/*.yaml; do
      [ -e "$f" ] || continue; found=1
      printf '  wave %-2s  %-28s %s\n' "$(desc_field "$f" syncWave)" "$(basename "$f" .yaml)" "$(desc_field "$f" chartRevision)"
    done
    [ "$found" -eq 1 ] || echo "  (none)"
  done
}

cmd_matrix() {
  printf '| component |'; for cl in $CLUSTERS; do printf ' %s |' "$cl"; done; printf '\n'
  printf '|---|';         for cl in $CLUSTERS; do printf ':--:|'; done;        printf '\n'
  for c in $(catalog_components); do
    printf '| %s |' "$c"
    for cl in $CLUSTERS; do
      hit=0
      for f in "$HERE/$cl"/*.yaml; do
        [ -e "$f" ] || continue
        [ "$(desc_field "$f" chartPath)" = "$(catalog_field "$c" chartPath)" ] && hit=1
      done
      if [ "$hit" -eq 1 ]; then printf ' yes |'; else printf ' -- |'; fi
    done
    printf '\n'
  done
}

refresh_readme() {
  [ -f "$README" ] || return 0
  grep -q '<!-- MATRIX:START -->' "$README" || return 0
  mfile="$(mktemp)"; cmd_matrix > "$mfile"
  tmp="$(mktemp)"
  awk -v mf="$mfile" '
    /<!-- MATRIX:START -->/ { print; while ((getline l < mf) > 0) print l; close(mf); skip=1; next }
    /<!-- MATRIX:END -->/   { skip=0 }
    !skip { print }
  ' "$README" > "$tmp" && mv "$tmp" "$README"
  rm -f "$mfile"
  echo "refreshed matrix in $README"
}

cmd_validate() {
  rc=0
  for cl in $CLUSTERS; do
    for f in "$HERE/$cl"/*.yaml; do
      [ -e "$f" ] || continue
      comp="$(basename "$f" .yaml)"
      # Every field the appset template reads must be present: missingkey=error
      # fails generation for EVERY component of the cluster, not just this one.
      for k in chartPath chartRevision releaseName namespace syncWave; do
        grep -q "^$k:" "$f" || { echo "FAIL $cl/$comp: missing $k"; rc=1; }
      done
      cp="$(desc_field "$f" chartPath)"; cv="$(desc_field "$f" chartRevision)"
      case "$cv" in
        "$cp"-[0-9]*.[0-9]*.[0-9]*) ;;
        *) echo "FAIL $cl/$comp: chartRevision '$cv' is not $cp-X.Y.Z (a branch is not a pin)"; rc=1 ;;
      esac
      [ -f "$HERE/values/$cl/$comp.yaml" ] || { echo "FAIL $cl/$comp: no platform/values/$cl/$comp.yaml"; rc=1; }
      # Catalog entry: by file name, or by chartPath for per-tenant descriptors.
      cat_comp="$comp"
      known_component "$comp" || cat_comp="$(for c in $(catalog_components); do [ "$(catalog_field "$c" chartPath)" = "$cp" ] && echo "$c"; done | head -1)"
      [ -n "$cat_comp" ] || { echo "FAIL $cl/$comp: chartPath '$cp' is not in catalog.yaml"; rc=1; continue; }
      # Drift is a WARN, not a failure: adopt-in-place descriptors legitimately
      # override the release name or namespace of the live release they take over.
      for k in releaseName namespace syncWave; do
        want="$(catalog_field "$cat_comp" "$k")"; got="$(desc_field "$f" "$k")"
        [ "$cat_comp" = "$comp" ] || [ "$k" != releaseName ] || continue
        [ "$want" = "$got" ] || echo "WARN $cl/$comp: $k is '$got', catalog says '$want'"
      done
    done
    # A values file without a descriptor is dead config, nothing more.
    for v in "$HERE/values/$cl"/*.yaml; do
      [ -e "$v" ] || continue
      [ -f "$HERE/$cl/$(basename "$v")" ] || echo "WARN $cl: values/$(basename "$v") has no descriptor (component disabled or pending)"
    done
  done
  [ "$rc" -eq 0 ] && echo "validate: OK"
  return "$rc"
}

[ $# -ge 1 ] || die "usage: $(basename "$0") {add|remove|list|bump|matrix|validate} ..."
sub="$1"; shift
case "$sub" in
  add)      cmd_add "$@" ;;
  remove)   cmd_remove "$@" ;;
  list)     cmd_list "$@" ;;
  bump)     cmd_bump "$@" ;;
  matrix)   cmd_matrix; refresh_readme ;;
  validate) cmd_validate ;;
  *)        die "unknown command '$sub' (add|remove|list|bump|matrix|validate)" ;;
esac
