#!/usr/bin/env bash
# Delete obsolete pipeline definitions and the build-validation policies that still point at
# them (e.g. the single CI-only pipeline a repository had before it moved to per-service
# CI/CD/PR pipelines). DRY RUN BY DEFAULT: prints what it would delete; --apply deletes.
#
# Exact-name match only, never a pattern: a typo must delete nothing rather than something.
# Policies go first, so no PR is left blocked on a validation pipeline that no longer exists.
#
# Usage:
#   ORG=https://dev.azure.com/example-org PROJECT=platform REPO=payments \
#     ./delete-unused-pipelines.sh "payments" "payments-legacy-ci"            # dry run
#   ... ./delete-unused-pipelines.sh --apply "payments" "payments-legacy-ci"  # delete
#
# Prerequisites: az login; az extension add --name azure-devops; jq

set -euo pipefail

: "${ORG:?set ORG}"
: "${PROJECT:?set PROJECT}"
: "${REPO:?set REPO}"
BRANCH="${BRANCH:-main}"

APPLY=false
NAMES=()
for a in "$@"; do
  case "$a" in --apply) APPLY=true ;; *) NAMES+=("$a") ;; esac
done
[ "${#NAMES[@]}" -gt 0 ] || { echo "usage: $0 [--apply] <pipeline name>..." >&2; exit 2; }
$APPLY || echo ">>> DRY RUN: nothing will be deleted. Re-run with --apply. <<<"

az_dev() { az "$@" --org "$ORG" --project "$PROJECT"; }
act() { if $APPLY; then "$@"; echo "   [deleted] $LABEL"; else echo "   [would delete] $LABEL"; fi; }

REPO_ID="$(az_dev repos show --repository "$REPO" --query id -o tsv | tr -d '\r')"
POLICIES="$(az_dev repos policy list --repository-id "$REPO_ID" --branch "$BRANCH" -o json 2>/dev/null || echo '[]')"

for name in "${NAMES[@]}"; do
  echo "-- $name"
  id="$(az_dev pipelines list --query "[?name=='$name'].id" -o tsv 2>/dev/null | tr -d '\r')"
  if [ -z "$id" ]; then echo "   [skip] not found"; continue; fi
  for pid in $(jq -r --argjson d "$id" '.[] | select(.settings.buildDefinitionId == $d) | .id' <<< "$POLICIES"); do
    LABEL="branch policy $pid (build validation -> $name)"
    act az_dev repos policy delete --id "$pid" --yes --output none
  done
  LABEL="pipeline $name (id $id)"
  act az_dev pipelines delete --id "$id" --yes --output none
done
$APPLY && echo "Done." || echo "Dry run complete."
