#!/usr/bin/env bash
# Build-validation branch policies: a PR into the target branch cannot complete until the
# matching "-pr" pipeline passed. Idempotent: an existing policy for the same pipeline and
# branch is skipped.
#
# WHY THIS SCRIPT EXISTS AT ALL: for Azure Repos, the `pr:` block in a YAML file is IGNORED.
# PR validation is configured only through branch policies; a PR.yml with a perfect `pr:` trigger
# and no policy never runs. Each policy's PATH FILTER must therefore mirror the `paths.include` of
# that PR.yml by hand, or a PR touching only one service would queue every service's validation.
#
# Input: a manifest, one policy per line,  <pipeline-name>|<display name>|<path filter>
#   payments-api-pr|PR: payments-api|/src/Payments.Api/*;/charts/payments-api/*;/pipelines/api/*
# Path filter: semicolon-separated, leading `/` required, `!` prefix excludes.
#
# Usage:
#   ORG=https://dev.azure.com/example-org PROJECT=platform REPO=payments \
#     ./set-branch-policies.sh policies.manifest
# Run after create-and-group-pipelines.sh (the -pr pipelines must exist).

set -euo pipefail

MANIFEST="${1:?usage: $0 <manifest file>}"
: "${ORG:?set ORG}"
: "${PROJECT:?set PROJECT}"
: "${REPO:?set REPO}"
BRANCH="${BRANCH:-main}"

az_dev() { az "$@" --org "$ORG" --project "$PROJECT"; }

REPO_ID="$(az_dev repos show --repository "$REPO" --query id -o tsv | tr -d '\r')"
echo "Repository $REPO = $REPO_ID; branch $BRANCH"

grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | tr -d '\r' | while IFS='|' read -r PIPELINE DISPLAY FILTER; do
  echo "-- $DISPLAY"
  PIPELINE_ID="$(az_dev pipelines list --query "[?name=='$PIPELINE'].id" -o tsv 2>/dev/null | tr -d '\r')"
  if [ -z "$PIPELINE_ID" ]; then
    echo "   [skip] pipeline $PIPELINE not found; run create-and-group-pipelines.sh first."
    continue
  fi
  # JMESPath number literals need backticks; the branch is matched client-side for CLI-version safety.
  EXISTING="$(az_dev repos policy list --repository-id "$REPO_ID" \
    --query "[?settings.buildDefinitionId==\`$PIPELINE_ID\` && contains(settings.scope[].refName, 'refs/heads/$BRANCH')].id" \
    -o tsv 2>/dev/null | tr -d '\r' || true)"
  if [ -n "$EXISTING" ]; then
    echo "   [skip] policy exists (id $EXISTING)"
    continue
  fi
  az_dev repos policy build create \
    --repository-id "$REPO_ID" --branch "$BRANCH" --branch-match-type exact \
    --build-definition-id "$PIPELINE_ID" --display-name "$DISPLAY" \
    --blocking true --enabled true --manual-queue-only false \
    --queue-on-source-update-only true --valid-duration 0 \
    --path-filter "$FILTER" --output none
  echo "   [ok] created"
done
echo "Done."
