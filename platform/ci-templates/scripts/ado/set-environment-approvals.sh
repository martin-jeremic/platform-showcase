#!/usr/bin/env bash
# Add a manual Approval check to Azure DevOps Environments. A deployment job that targets the
# Environment (every Promote_* stage) then pauses until an approver approves it, and THAT
# approval is the deployment: on approval the job writes the digest + chart pin to GitOps.
#
# Environments that must stay ungated (Development: dev follows main automatically) are simply
# not passed. Idempotent: an Environment that already has an Approval check is skipped.
#
# Uses the Pipelines Checks REST API with a bearer token from `az login` (no PAT). The Approval
# check type GUID 8c6f20a7-a545-4486-9777-f762fafe0d4d is fixed across all ADO organisations.
#
# Usage:
#   ORG_NAME=example-org PROJECT=platform \
#   APPROVERS="approver@example.com,release-manager@example.com" \
#     ./set-environment-approvals.sh Production
#   ./set-environment-approvals.sh --approver approver@example.com Stage Demo Production
#
# Settings (env):
#   APPROVERS            comma-separated identities (or repeat --approver)
#   REQUIRED_APPROVERS   how many must approve, default 1
#   TIMEOUT_MINUTES      how long a request stays open, default 2880 (48 h)
# Self-approval is OFF: whoever triggered the run cannot approve it.
#
# Prerequisites: az login (an identity with Environment Administrator), the azure-devops
# extension, curl, jq. Environments appear on the first run that targets them, or create them
# in Pipelines > Environments first.

set -euo pipefail

: "${ORG_NAME:?set ORG_NAME, e.g. example-org}"
: "${PROJECT:?set PROJECT}"
REQUIRED_APPROVERS="${REQUIRED_APPROVERS:-1}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-2880}"
APPROVAL_TYPE_ID="8c6f20a7-a545-4486-9777-f762fafe0d4d"
ADO_RESOURCE="499b84ac-1321-427f-aa17-267ca6975798"

IFS=',' read -r -a APPROVER_LIST <<< "${APPROVERS:-}"
ENVIRONMENTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --approver) APPROVER_LIST+=("${2:?--approver needs a value}"); shift 2 ;;
    *) ENVIRONMENTS+=("$1"); shift ;;
  esac
done
[ "${#ENVIRONMENTS[@]}" -gt 0 ] || { echo "usage: $0 [--approver id]... <environment>..." >&2; exit 2; }

ORG_URL="https://dev.azure.com/$ORG_NAME"
PROJECT_ENC="$(jq -rn --arg p "$PROJECT" '$p | @uri')"
ENVS_API="$ORG_URL/$PROJECT_ENC/_apis/distributedtask/environments?api-version=7.1"
CHECKS_API="$ORG_URL/$PROJECT_ENC/_apis/pipelines/checks/configurations?api-version=7.1-preview.1"

TOKEN="$(az account get-access-token --resource "$ADO_RESOURCE" --query accessToken -o tsv | tr -d '\r')"
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
ado() { curl -sf -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }

echo "Resolving approvers..."
IDS=()
for who in "${APPROVER_LIST[@]}"; do
  who="$(echo "$who" | xargs)"
  [ -n "$who" ] || continue
  id="$(az devops user show --org "$ORG_URL" --user "$who" --query user.originId -o tsv 2>/dev/null | tr -d '\r' || true)"
  if [ -z "$id" ]; then echo "  [warn] cannot resolve $who"; continue; fi
  echo "  $who -> $id"
  IDS+=("$id")
done
[ "${#IDS[@]}" -gt 0 ] || { echo "ERROR: no approver could be resolved (set APPROVERS or --approver)." >&2; exit 1; }
APPROVERS_JSON="$(printf '%s\n' "${IDS[@]}" | jq -R '{id: .}' | jq -s .)"

for env in "${ENVIRONMENTS[@]}"; do
  echo "-- $env"
  env_id="$(ado "$ENVS_API&name=$(jq -rn --arg e "$env" '$e | @uri')" | jq -r '.value[0].id // empty')"
  if [ -z "$env_id" ]; then
    echo "   [skip] Environment does not exist yet (created on the first run that targets it)."
    continue
  fi
  existing="$(ado "$CHECKS_API&resourceType=environment&resourceId=$env_id" \
    | jq -r --arg t "$APPROVAL_TYPE_ID" '[.value[] | select((.type.id | ascii_downcase) == $t)][0].id // empty')"
  if [ -n "$existing" ]; then
    echo "   [skip] Approval check exists (id $existing)."
    continue
  fi
  jq -n \
    --arg type "$APPROVAL_TYPE_ID" --argjson approvers "$APPROVERS_JSON" \
    --argjson required "$REQUIRED_APPROVERS" --argjson timeout "$TIMEOUT_MINUTES" \
    --argjson envId "$env_id" --arg envName "$env" '
    { type: { id: $type, name: "Approval" },
      settings: {
        approvers: $approvers,
        requiredApproverCount: $required,
        allowApproversToApproveOwnRuns: false,
        instructions: ("Approving writes the validated digest and chart pin for " + $envName + " to GitOps; Argo CD deploys it.")
      },
      resource: { type: "environment", id: ($envId | tostring) },
      timeout: $timeout }' > "$BODY"
  if ado -X POST "$CHECKS_API" --data "@$BODY" > /dev/null; then
    echo "   [ok] Approval check created."
  else
    echo "   [warn] API call failed: the identity needs Environment Administrator (or Project Administrator)."
  fi
done
echo "Done."
