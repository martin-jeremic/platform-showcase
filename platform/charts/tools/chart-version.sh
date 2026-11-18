#!/usr/bin/env bash
# chart-version.sh -- per-chart versioning for the platform charts.
#
# The whole scheme rests on one invariant, shared with azure-pipelines.yml and the
# gitops descriptors (gitops/platform/island/.../RELEASING.md):
#
#     tag name == <chart directory> + "-" + <Chart.yaml version>
#
# Chart.yaml is the single source of truth; a tag is cut FROM it, never the other
# way round. No semver inference, no commit-message parsing. Each subcommand is a
# different consumer of that invariant:
#
#   check                      FAIL if any chart's content moved since its current
#                              tag without a version bump. That state fails
#                              silently everywhere else: no new tag is cut, the
#                              descriptor keeps pinning the old one, and Argo
#                              renders stale content while reporting Synced.
#   autobump                   For every chart in that state, bump the patch
#                              version (X.Y.Z -> X.Y.Z+1) in Chart.yaml, in place.
#                              Idempotent -- a second run finds no tag for the new
#                              version and changes nothing. That idempotence is
#                              what stops the CI push-triggers-build loop.
#   bump <chart> [level]       Deliberate manual bump; level = patch|minor|major.
#   tag [--push]               Cut the missing annotated tag for every chart.
#                              Without --push it only PRINTS what it would cut;
#                              with --push it tags and pushes (CI, on main).
#                              Existing tags are always skipped -- this tool cannot
#                              move a tag.
#   promote <gitops-platform-dir> <cluster> [--push]
#                              Bump every gitops descriptor whose chartRevision is
#                              behind the chart's current tag (descriptors live in
#                              <gitops-platform-dir>/<cluster>/<chart>.yaml), via
#                              that repo's own component.sh bump, which preserves the
#                              descriptor comments), then component.sh validate,
#                              one commit, push. A component without a descriptor
#                              is skipped (disabled/pending). A tag NOT ON ORIGIN
#                              is skipped with a warning -- a descriptor must never
#                              reference a tag origin lacks, or the Application
#                              goes ComparisonError. Without --push it prints what
#                              it would do and touches nothing.
#
# Run from platform/charts/. Needs a full clone with tags: in CI that means
# fetchDepth: 0 and fetchTags: true, or every existence check comes up empty and
# the tool misjudges all charts at once.

set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  # print the header comment block (everything up to the first non-# line)
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
  exit 2
}

charts() { for c in */Chart.yaml; do echo "${c%/Chart.yaml}"; done; }

chart_version() { # <chart-dir> -> version from Chart.yaml
  awk '/^version:/{print $2; exit}' "$1/Chart.yaml"
}

require_semver() { # <chart-dir> <version>
  case "$2" in
    *[!0-9.]* | "" | .* | *. | *..*)
      echo "ERROR $1: Chart.yaml version '$2' is not plain X.Y.Z" >&2
      exit 2 ;;
  esac
}

next_version() { # <version> <level>
  local maj min pat
  IFS=. read -r maj min pat <<<"$1"
  case "$2" in
    major) echo "$((maj + 1)).0.0" ;;
    minor) echo "${maj}.$((min + 1)).0" ;;
    patch) echo "${maj}.${min}.$((pat + 1))" ;;
    *)     echo "ERROR: bump level '$2' is not patch|minor|major" >&2; exit 2 ;;
  esac
}

set_version() { # <chart-dir> <new-version>
  # yq edits the one key and keeps the changelog comments around it. Without yq,
  # an anchored sed on the top-level `version:` line does the same -- the only
  # line in Chart.yaml that starts with that key.
  if command -v yq >/dev/null 2>&1; then
    V="$2" yq -i '.version = strenv(V)' "$1/Chart.yaml"
  else
    sed -i "s/^version:.*/version: $2/" "$1/Chart.yaml"
  fi
}

tag_exists() { git rev-parse -q --verify "refs/tags/$1" >/dev/null; }

changed_since_tag() { ! git diff --quiet "$1" HEAD -- "$2/"; }

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  check)
    fail=0
    for chart in $(charts); do
      ver=$(chart_version "$chart"); require_semver "$chart" "$ver"
      tag="$chart-$ver"
      # No tag for the declared version = bumped, tag not cut yet. Healthy.
      tag_exists "$tag" || continue
      if changed_since_tag "$tag" "$chart"; then
        echo "FAIL $chart: content changed since $tag but version is still $ver."
        echo "     Bump version in $chart/Chart.yaml, or the cluster keeps rendering $tag."
        fail=1
      fi
    done
    [ "$fail" -eq 0 ] && echo "check: every changed chart carries a bumped version"
    exit "$fail"
    ;;

  autobump)
    bumped=0
    for chart in $(charts); do
      ver=$(chart_version "$chart"); require_semver "$chart" "$ver"
      tag="$chart-$ver"
      tag_exists "$tag" || continue          # already hand-bumped: leave it alone
      changed_since_tag "$tag" "$chart" || continue
      new=$(next_version "$ver" patch)
      set_version "$chart" "$new"
      echo "bumped $chart: $ver -> $new (content changed since $tag)"
      bumped=1
    done
    [ "$bumped" -eq 0 ] && echo "autobump: nothing to bump"
    exit 0
    ;;

  bump)
    chart="${1:-}"
    [ -n "$chart" ] || usage
    level="${2:-patch}"
    [ -f "$chart/Chart.yaml" ] || { echo "ERROR: no chart at $chart/Chart.yaml" >&2; exit 2; }
    ver=$(chart_version "$chart"); require_semver "$chart" "$ver"
    new=$(next_version "$ver" "$level")
    set_version "$chart" "$new"
    echo "bumped $chart: $ver -> $new"
    ;;

  tag)
    push=0
    [ "${1:-}" = "--push" ] && push=1
    for chart in $(charts); do
      ver=$(chart_version "$chart"); require_semver "$chart" "$ver"
      tag="$chart-$ver"
      if tag_exists "$tag"; then
        echo "skip      $tag (exists)"
        continue
      fi
      if [ "$push" -eq 1 ]; then
        # Annotated, not lightweight: it records who cut it and when, and this is
        # the artifact rollback depends on.
        git tag -a "$tag" -m "$chart $ver"
        git push origin "refs/tags/$tag"
        echo "cut       $tag"
      else
        echo "would cut $tag (dry run -- pass --push to create and push)"
      fi
    done
    ;;

  promote)
    gitops="${1:-}"
    cluster="${2:-}"
    push=0
    [ "${3:-}" = "--push" ] && push=1
    [ -n "$gitops" ] && [ -n "$cluster" ] || usage
    desc_dir="$gitops/$cluster"
    [ -d "$desc_dir" ] || { echo "ERROR: no descriptor dir at $desc_dir" >&2; exit 2; }

    # One remote round-trip instead of one per chart. The origin check is the
    # ordering guard: a descriptor referencing a tag origin lacks makes the
    # Application ComparisonError, so an uncut tag is skipped, never promoted.
    origin_tags=$(git ls-remote --tags origin | awk '{print $2}')

    bumps=""
    for chart in $(charts); do
      ver=$(chart_version "$chart"); require_semver "$chart" "$ver"
      tag="$chart-$ver"
      desc="$desc_dir/$chart.yaml"
      [ -f "$desc" ] || continue            # not deployed on this cluster, by design
      current=$(awk '/^chartRevision:/{print $2; exit}' "$desc")
      [ "$current" = "$tag" ] && continue
      if ! grep -qxF "refs/tags/$tag" <<<"$origin_tags"; then
        echo "WARN      $chart: tag $tag not on origin -- skipping (cut it first: 'tag --push')"
        continue
      fi
      if [ "$push" -eq 1 ]; then
        (cd "$gitops" && sh ./component.sh bump "$(basename "$cluster")" "$chart" "$tag" >/dev/null)
        echo "promote   $chart: $current -> $tag"
      else
        echo "would promote $chart: $current -> $tag (dry run -- pass --push)"
      fi
      if [ -n "$bumps" ]; then bumps="$bumps, $chart -> $tag"; else bumps="$chart -> $tag"; fi
    done

    [ -n "$bumps" ] || { echo "promote: every descriptor already pins its chart's current tag"; exit 0; }
    [ "$push" -eq 1 ] || exit 0

    (
      cd "$gitops"
      sh ./component.sh validate
      git add -A "$cluster"
      git commit -m "ci: promote $bumps"
      # The checkout may be detached and someone may have pushed meanwhile:
      # replay the promote commit onto the current remote tip and push, retrying a
      # rejected (non-fast-forward) push a few times rather than failing the stage.
      for attempt in 1 2 3 4 5; do
        git fetch origin main
        git rebase FETCH_HEAD
        if git push origin HEAD:refs/heads/main; then exit 0; fi
        echo "push rejected (attempt $attempt) -- someone pushed meanwhile; rebasing again"
        sleep $((attempt * 3))
      done
      echo "ERROR: could not push the promote commit after 5 attempts" >&2
      exit 1
    )
    ;;

  *)
    usage
    ;;
esac
