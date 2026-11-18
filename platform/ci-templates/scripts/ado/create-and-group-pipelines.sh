#!/usr/bin/env bash
# Register a repository's pipelines in Azure DevOps and group them into one folder. Idempotent:
# an existing pipeline is skipped, an existing folder is reused, safe to re-run.
#
# Input: a manifest with one pipeline per line,  <pipeline-name>|<yaml path in the repo>
#   payments-api-ci|pipelines/api/CI.yml
#   payments-api-cd|pipelines/api/CD.yml
#   payments-api-pr|pipelines/api/PR.yml
# Blank lines and lines starting with # are ignored.
#
# ORDER MATTERS: every "-ci" pipeline is registered BEFORE everything else. A CD pipeline names
# its CI as a `resources.pipelines` source, and ADO resolves that name when the CD definition is
# created; a CD registered first is created with a broken trigger that never fires. So the names
# are load-bearing too: keep them identical to the `source:` in each CD.yml.
#
# Usage:
#   ORG=https://dev.azure.com/example-org PROJECT=platform REPO=payments FOLDER=payments \
#     ./create-and-group-pipelines.sh pipelines.manifest
#
# Prerequisites: az login; az extension add --name azure-devops

set -euo pipefail

MANIFEST="${1:?usage: $0 <manifest file>}"
: "${ORG:?set ORG, e.g. https://dev.azure.com/example-org}"
: "${PROJECT:?set PROJECT}"
: "${REPO:?set REPO (the Azure Repos repository holding the YAML)}"
: "${FOLDER:?set FOLDER (pipeline folder, without the leading backslash)}"
BRANCH="${BRANCH:-main}"

az_dev() { az "$@" --org "$ORG" --project "$PROJECT"; }

pipeline_id() {
  # tr -d '\r': az on Windows ends lines with CRLF, and "123\r" is not "123".
  az_dev pipelines list --query "[?name=='$1'].id" -o tsv 2>/dev/null | tr -d '\r'
}

mapfile -t ENTRIES < <(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | tr -d '\r')
CI=() REST=()
for e in "${ENTRIES[@]}"; do
  case "${e%%|*}" in *-ci) CI+=("$e") ;; *) REST+=("$e") ;; esac
done

echo "== Phase 1: register (CI first: ${#CI[@]} CI, ${#REST[@]} other)"
for e in "${CI[@]}" "${REST[@]}"; do
  name="${e%%|*}" yml="${e#*|}"
  if [ -n "$(pipeline_id "$name")" ]; then
    echo "  [skip]   $name (exists)"
    continue
  fi
  az_dev pipelines create --name "$name" --repository "$REPO" --repository-type tfsgit \
    --branch "$BRANCH" --yml-path "$yml" --skip-first-run true --output none
  echo "  [create] $name <- $yml"
done

echo "== Phase 2: group into \\$FOLDER"
az_dev pipelines folder create --path "\\$FOLDER" --output none 2>/dev/null || true
for e in "${ENTRIES[@]}"; do
  name="${e%%|*}"
  id="$(pipeline_id "$name")"
  if [ -z "$id" ]; then echo "  [skip]   $name (not found)"; continue; fi
  az_dev pipelines update --id "$id" --new-folder-path "\\$FOLDER" --output none
  echo "  [ok]     $name -> \\$FOLDER"
done
echo "Done."
