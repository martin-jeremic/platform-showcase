#!/usr/bin/env bash
# Seed the Key Vault objects one service's SecretProviderClass declares, BEFORE its first
# promotion. Generic for every service in this repository (each values.yaml lists its objects and
# the exact command line in its "Secrets" block).
#
#   VAULT=kv-org-dev  bash bootstrap/populate-kv.sh <app> <object>...
#   VAULT=kv-org-prod bash bootstrap/populate-kv.sh access-api database identity-client-secret
#
# WHY BEFORE THE PROMOTION
# The Secrets Store CSI driver fails the WHOLE mount if any single declared object is missing from
# the vault. The pod sits in ContainerCreating with no useful event, and the Argo Application can
# still look Synced. Seed first, promote second.
#
# WHAT LIVES IN KEY VAULT
# Only real secrets, ONE PLAIN VALUE PER OBJECT, named <app>--<object>. No JSON blobs, no Base64:
# the old charts read one Base64-encoded JSON blob per service, which made every rotation a
# hand-edit of an encoded document, and put hostnames and queue names (not secrets) out of review.
# Everything non-secret is in apps/<app>/<env>/values.yaml.
#
# WHERE EACH VALUE COMES FROM, per object
#   1. The environment variable named after the object: upper case, `-` -> `_`
#      (identity-client-secret -> IDENTITY_CLIENT_SECRET). For a new vault or a rotation.
#   2. Otherwise, ONE-TIME MIGRATION from the legacy blob: set LEGACY_BLOB to the old object's
#      name and LEGACY_MAP to "<object>=<jq path> ..." (e.g. "database=.connectionStrings.Default").
#      The first run moves today's values across without anyone retyping a secret; once every
#      environment runs the new chart the blob is deleted and only path 1 remains.
#   3. Neither: the script stops BEFORE writing anything (no half-seeded vault).
#
# PREREQUISITES
#   Any bash with az and jq (Git Bash, WSL or Linux). `az login` as an identity with
#   "Key Vault Secrets Officer" on $VAULT.
set -euo pipefail

: "${VAULT:?set VAULT, e.g. kv-org-dev or kv-org-prod}"
APP="${1:?usage: VAULT=<vault> $0 <app> <object>...}"
shift
[ "$#" -gt 0 ] || { echo "usage: VAULT=<vault> $0 <app> <object>..." >&2; exit 2; }

# Optional legacy source (path 2).
declare -A LEGACY_PATH=()
for pair in ${LEGACY_MAP:-}; do LEGACY_PATH["${pair%%=*}"]="${pair#*=}"; done
LEGACY_JSON=""
if [ -n "${LEGACY_BLOB:-}" ]; then
  # az and jq on Windows end lines with CRLF; a stray \r would silently become part of a secret.
  raw="$(az keyvault secret show --vault-name "$VAULT" --name "$LEGACY_BLOB" --query value -o tsv | tr -d '\r')"
  LEGACY_JSON="$(printf '%s' "$raw" | base64 -d)"
fi

NAMES=() VALUES=()
echo "Resolving $# object(s) for $APP in $VAULT ..."
for object in "$@"; do
  var="$(printf '%s' "$object" | tr '[:lower:]-' '[:upper:]_')"
  value="${!var:-}" source="\$$var"
  if [ -z "$value" ] && [ -n "$LEGACY_JSON" ] && [ -n "${LEGACY_PATH[$object]:-}" ]; then
    value="$(printf '%s' "$LEGACY_JSON" | jq -r "${LEGACY_PATH[$object]} // empty" | tr -d '\r')"
    source="legacy $LEGACY_BLOB ${LEGACY_PATH[$object]}"
  fi
  if [ -z "$value" ]; then
    echo "ERROR: $APP--$object: set $var (nothing to derive it from). Nothing was written." >&2
    exit 1
  fi
  NAMES+=("$APP--$object")
  VALUES+=("$value")
  echo "  $APP--$object  <-  $source"
done

# --value=<secret> as ONE argument, so a value starting with "-" is not read as an option. From
# bash, `az` starts the CLI's Python directly (no cmd.exe), so & | ^ % " \ arrive unchanged.
# MSYS_NO_PATHCONV=1 stops Git Bash rewriting a value that starts with "/" into a Windows path
# (a connection string or a URL path would otherwise be silently corrupted).
echo "Writing ${#NAMES[@]} object(s) to $VAULT ..."
for i in "${!NAMES[@]}"; do
  MSYS_NO_PATHCONV=1 az keyvault secret set --vault-name "$VAULT" --name "${NAMES[$i]}" \
    --value="${VALUES[$i]}" --output none
  echo "  set ${NAMES[$i]}"
done

echo
echo "Verify: az keyvault secret list --vault-name $VAULT --query \"[?starts_with(name,'${APP}--')].name\" -o tsv"
