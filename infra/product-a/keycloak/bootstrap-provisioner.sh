#!/usr/bin/env bash
# =============================================================================
# bootstrap-provisioner.sh
#
# Seeds the ONE thing OpenTofu cannot create for itself: the
# `terraform-provisioner` client it authenticates as. A config cannot create the
# credential it needs in order to run, so this chicken-and-egg is broken by hand,
# once per realm, before the first `tofu plan`.
#
# Creates, idempotently:
#   realm  : optional (--create-realm), for greenfield realms. Created MINIMAL;
#            the root owns every real setting through manage_realm = true.
#   client : terraform-provisioner -- CONFIDENTIAL, service account ONLY. No
#            standard flow, no direct grants, no implicit. It never represents a
#            human.
#   role   : realm-management -> realm-admin on that service account.
#
# WHY A PER-REALM CLIENT AND NOT THE MASTER ADMIN
# This client authenticates against the TARGET realm via client_credentials, so a
# leaked dev credential cannot touch another realm, and neither can touch prod (a
# different instance). That containment is the point. realm-admin is deliberately
# broad because OpenTofu owns the whole realm and anything narrower fails partway
# through an apply; --granular-roles assigns the explicit set instead.
#
# USAGE
#   # prompts for the admin password -- nothing sensitive in argv or history
#   ./bootstrap-provisioner.sh --realm product-a-dev --admin-user <admin>
#
#   # greenfield realm, stored straight into Key Vault (needs `az login`)
#   ./bootstrap-provisioner.sh --realm product-a --create-realm --admin-user <admin> \
#       --server https://app.product-a.example.net/keycloak --key-vault kv-product-a-prod
#
#   # CI: credentials from the environment, never from argv
#   KC_ADMIN_USER=<admin> KC_ADMIN_PASSWORD="$(read from your secret store)" \
#     ./bootstrap-provisioner.sh --realm product-a-dev --key-vault kv-product-a-dev
#
#   # self-test of the helper functions, no network
#   ./bootstrap-provisioner.sh --self-test
#
# Options (also settable as env vars):
#   --server URL       KC_SERVER       default https://dev.example.com/keycloak
#   --realm NAME       KC_REALM        required
#   --admin-user USER  KC_ADMIN_USER   master-realm admin
#   --client-id ID     CLIENT_ID       default terraform-provisioner
#   --create-realm     CREATE_REALM    create the realm if absent
#   --rotate-secret    ROTATE_SECRET   regenerate the secret even if the client exists
#   --granular-roles   GRANULAR_ROLES  explicit role set instead of realm-admin
#   --key-vault NAME   KEY_VAULT       store the secret in this vault
#   --print-secret     PRINT_SECRET    print the secret on stdout (when no vault is used)
#
# The admin password comes ONLY from $KC_ADMIN_PASSWORD or an interactive prompt.
# There is no --admin-password flag: an argument is visible in `ps` and lands in
# shell history. (The script this replaces had one, and its usage examples carried
# a literal password.)
#
# Idempotent: a re-run detects the realm, client and roles and only fills gaps. The
# secret is NOT regenerated unless --rotate-secret is passed; rotating silently
# would break every runner still holding the old one.
#
# Needs curl + jq; runs in Git Bash, a Linux CI agent, or the Keycloak pod. It talks
# to the Admin REST API directly, so no Keycloak binaries are needed.
# =============================================================================
set -euo pipefail

KC_SERVER="${KC_SERVER:-https://dev.example.com/keycloak}"
REALM="${KC_REALM:-}"
CLIENT_ID="${CLIENT_ID:-terraform-provisioner}"
CREATE_REALM="${CREATE_REALM:-false}"
ROTATE_SECRET="${ROTATE_SECRET:-false}"
GRANULAR_ROLES="${GRANULAR_ROLES:-false}"
KEY_VAULT="${KEY_VAULT:-}"
PRINT_SECRET="${PRINT_SECRET:-false}"
SELF_TEST=false

# Initialised rather than left unset: `set -u` would abort on the first reference.
KC_ADMIN_USER="${KC_ADMIN_USER:-}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-}"

die() { echo "[ERROR] $*" >&2; exit 1; }

# Prints the header block, whatever its length -- no hard-coded line range to drift.
usage() { sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --server)         KC_SERVER="$2"; shift 2 ;;
    --realm)          REALM="$2"; shift 2 ;;
    --admin-user)     KC_ADMIN_USER="$2"; shift 2 ;;
    --client-id)      CLIENT_ID="$2"; shift 2 ;;
    --key-vault)      KEY_VAULT="$2"; shift 2 ;;
    --create-realm)   CREATE_REALM=true; shift ;;
    --rotate-secret)  ROTATE_SECRET=true; shift ;;
    --granular-roles) GRANULAR_ROLES=true; shift ;;
    --print-secret)   PRINT_SECRET=true; shift ;;
    --self-test)      SELF_TEST=true; shift ;;
    --admin-password) die "--admin-password was removed: set KC_ADMIN_PASSWORD or answer the prompt." ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; echo "Try --help." >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || die "jq is required"

# The granular alternative to realm-admin. Every one of these is needed for
# full-realm ownership; dropping any produces a 403 partway through an apply, not
# at plan time.
GRANULAR_ROLE_LIST="manage-realm manage-clients create-client view-clients query-clients \
manage-users view-users query-users view-realm manage-authorization"

# ---------------------------------------------------------------------------
# api METHOD PATH [JSON_BODY] [TIMEOUT_SECONDS]
#
# Sets two globals and prints NOTHING:
#   $HTTP_CODE  the status
#   $API_BODY   the response body
#
# It deliberately does not write to stdout. An earlier version did, so every
# caller wrote `x="$(api ... | jq ...)"`, which had two ways to fail silently:
#   1. Command substitution is a subshell, so the HTTP_CODE assignment was lost and
#      status checks read a stale value from an earlier call.
#   2. When Keycloak answered with an error OBJECT instead of the expected array,
#      `jq '.[0]'` failed; under pipefail + set -e the whole script died printing
#      one cryptic jq line -- exactly how a run created the realm and then stopped
#      without saying the client had not been created.
# Returning via globals removes both: no subshell, and every caller checks
# HTTP_CODE before jq sees the payload.
#
# TIMEOUT defaults to 60. Creating a realm needs far more: Keycloak generates a
# fresh key set per realm, and on an MSSQL-backed instance a realm POST took about
# 30 s. A flat 30 s timeout once expired with seconds to spare -- Keycloak finished
# the realm, curl gave up, HTTP came back as 000, and the script aborted before
# creating the client. Do not lower these.
# ---------------------------------------------------------------------------
HTTP_CODE=""
API_BODY=""
TOKEN=""
TOKEN_AT=0

# The master-realm admin token lives about 60 s and WILL expire mid-script.
# Deliberately NOT `curl -f`: with -f a bad password makes curl exit non-zero,
# pipefail fails the substitution, and set -e kills the script before any message
# is printed. Taking the body lets us report what Keycloak actually said.
auth() {
  local resp detail
  # The password travels on stdin (printf: no trailing newline), never in argv
  # where `ps` would show it.
  resp="$(printf '%s' "$KC_ADMIN_PASSWORD" | curl -s -m 20 -X POST \
    "$KC_SERVER/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli \
    --data-urlencode "username=$KC_ADMIN_USER" \
    --data-urlencode "password@-" || true)"
  TOKEN="$(printf '%s' "$resp" | jq -r '.access_token // empty' 2>/dev/null | tr -d '\r')"
  if [ -z "$TOKEN" ]; then
    detail="$(printf '%s' "$resp" | jq -r '.error_description // .error // empty' 2>/dev/null | tr -d '\r')"
    die "Could not authenticate to $KC_SERVER as '$KC_ADMIN_USER' (master realm).${detail:+ Server said: $detail}"
  fi
  TOKEN_AT=$SECONDS
}

api() {
  local method="$1" path="$2" body="${3:-}" tmo="${4:-60}" out
  # Refresh on staleness rather than hoping the script finishes in time.
  if [ $(( SECONDS - TOKEN_AT )) -gt 40 ]; then auth; fi

  if [ -n "$body" ]; then
    out="$(curl -s -m "$tmo" -w $'\n%{http_code}' -X "$method" "$KC_SERVER/admin/realms$path" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$body" || true)"
  else
    out="$(curl -s -m "$tmo" -w $'\n%{http_code}' -X "$method" "$KC_SERVER/admin/realms$path" \
      -H "Authorization: Bearer $TOKEN" || true)"
  fi
  HTTP_CODE="$(printf '%s' "$out" | tail -n1 | tr -d '\r')"
  API_BODY="$(printf '%s' "$out" | sed '$d')"
}

# Reads a value out of $API_BODY without ever letting jq abort the script: a type
# mismatch or missing key yields "", which the caller then reports properly. The
# `tr -d '\r'` matters on Windows, where some jq builds emit CRLF.
body_get() { printf '%s' "$API_BODY" | jq -r "$1" 2>/dev/null | tr -d '\r' || true; }

# Turns a non-2xx into a real message instead of a silent exit or a bare status.
expect() {
  local want="$1" what="$2" detail
  [ "$HTTP_CODE" = "$want" ] && return 0
  detail="$(body_get '.errorMessage // .error_description // .error // empty')"
  die "$what failed -- HTTP $HTTP_CODE${detail:+: $detail}"
}

FIRST_ID='if type=="array" then (.[0].id // empty) else empty end'

# ---------------------------------------------------------------------------
# --self-test: exercises the parsing helpers against canned payloads, offline.
# ---------------------------------------------------------------------------
if [ "$SELF_TEST" = "true" ]; then
  fail=0
  check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; fail=1; fi; }
  API_BODY='[{"id":"11111111-1111-1111-1111-111111111111","clientId":"x"}]'
  check "first id from array" "$(body_get "$FIRST_ID")" "11111111-1111-1111-1111-111111111111"
  API_BODY='{"error":"unknown_error"}'
  check "error object yields empty id" "$(body_get "$FIRST_ID")" ""
  API_BODY=$'{"value":"abc"}\r'
  check "CR stripped" "$(body_get '.value // empty')" "abc"
  API_BODY='not json'
  check "non-JSON yields empty" "$(body_get '.value // empty')" ""
  HTTP_CODE=201
  ( expect 201 "create" ) && echo "  ok   expect passes on match" || { echo "  FAIL expect"; fail=1; }
  [ "$fail" = 0 ] && echo ">> self-test passed" || die "self-test failed"
  exit 0
fi

[ -n "$REALM" ]         || die "--realm is required (or set KC_REALM). Try --help."
[ -n "$KC_ADMIN_USER" ] || die "--admin-user is required (or set KC_ADMIN_USER)."
command -v curl >/dev/null || die "curl is required"

# Prompt only as a last resort, and only when there is a terminal: in CI there is
# none, and a script that blocks forever on stdin is worse than one that fails.
if [ -z "$KC_ADMIN_PASSWORD" ]; then
  if [ -t 0 ]; then
    printf 'Keycloak password for %s@%s (master realm): ' "$KC_ADMIN_USER" "$KC_SERVER" >&2
    IFS= read -rs KC_ADMIN_PASSWORD
    printf '\n' >&2
  fi
  [ -n "$KC_ADMIN_PASSWORD" ] || die "No password. Set KC_ADMIN_PASSWORD or run interactively."
fi

auth
echo ">> Authenticated to $KC_SERVER (master realm) as '$KC_ADMIN_USER'"

# ---------------------------------------------------------------------------
# 1. Realm
# ---------------------------------------------------------------------------
api GET "/$REALM"
if [ "$HTTP_CODE" = "404" ]; then
  [ "$CREATE_REALM" = "true" ] || die "Realm '$REALM' does not exist. Pass --create-realm to create it."
  echo ">> Creating realm '$REALM' -- this takes ~30-60 s (Keycloak generates a key set) ..."
  api POST "" "$(jq -nc --arg r "$REALM" '{realm:$r, enabled:true}')" 300

  # A realm POST is slow enough that the answer can be lost even when the work
  # succeeded, so an inconclusive response is NOT treated as failure: re-read the
  # realm and let reality decide. Otherwise a slow instance leaves an orphaned realm
  # behind and reports that nothing was created.
  if [ "$HTTP_CODE" != "201" ]; then
    create_code="$HTTP_CODE"
    api GET "/$REALM"
    if [ "$HTTP_CODE" = "200" ]; then
      echo "   [warn] create returned HTTP $create_code, but realm '$REALM' exists. Continuing."
    else
      HTTP_CODE="$create_code"
      expect 201 "Creating realm '$REALM'"
    fi
  fi
  echo ">> Created realm '$REALM' (minimal -- tofu owns its settings)"

  # Re-authenticate before touching the new realm: Keycloak extends the master
  # admin composite AT realm creation, so authorisation derived from the old
  # session can lag by one request. One round trip removes a class of first-run 403.
  auth
elif [ "$HTTP_CODE" = "200" ]; then
  echo ">> Realm '$REALM' exists"
else
  expect 200 "Reading realm '$REALM'"
fi

# ---------------------------------------------------------------------------
# 2. The provisioner client
# ---------------------------------------------------------------------------
api GET "/$REALM/clients?clientId=$CLIENT_ID"
expect 200 "Listing clients in realm '$REALM'"
CID="$(body_get "$FIRST_ID")"

if [ -z "$CID" ]; then
  api POST "/$REALM/clients" "$(jq -nc --arg cid "$CLIENT_ID" '{
    clientId: $cid,
    protocol: "openid-connect",
    description: "OpenTofu provisioner for this realm. Service account only; never represents a human.",
    enabled: true,
    publicClient: false,
    serviceAccountsEnabled: true,
    standardFlowEnabled: false,
    implicitFlowEnabled: false,
    directAccessGrantsEnabled: false
  }')"
  expect 201 "Creating client '$CLIENT_ID'"

  api GET "/$REALM/clients?clientId=$CLIENT_ID"
  expect 200 "Re-reading client '$CLIENT_ID'"
  CID="$(body_get "$FIRST_ID")"
  [ -n "$CID" ] || die "Client '$CLIENT_ID' was created (HTTP 201) but is not in the client list"
  echo ">> Created client '$CLIENT_ID' ($CID)"
else
  echo ">> Client '$CLIENT_ID' already exists ($CID)"
fi

api GET "/$REALM/clients/$CID/service-account-user"
expect 200 "Reading the service account of '$CLIENT_ID'"
SA_USER_ID="$(body_get '.id // empty')"
[ -n "$SA_USER_ID" ] || die "Client '$CLIENT_ID' has no service account user -- serviceAccountsEnabled is off?"

# ---------------------------------------------------------------------------
# 3. Roles on the service account, from the realm-management client
# ---------------------------------------------------------------------------
api GET "/$REALM/clients?clientId=realm-management"
expect 200 "Looking up realm-management in '$REALM'"
RM_CID="$(body_get "$FIRST_ID")"
[ -n "$RM_CID" ] || die "No 'realm-management' client in realm '$REALM'"

if [ "$GRANULAR_ROLES" = "true" ]; then WANTED="$GRANULAR_ROLE_LIST"; else WANTED="realm-admin"; fi

api GET "/$REALM/users/$SA_USER_ID/role-mappings/clients/$RM_CID"
expect 200 "Reading current role mappings"
HELD="$(body_get 'if type=="array" then (.[].name) else empty end')"

TO_ADD="[]"
for ROLE in $WANTED; do
  if printf '%s\n' "$HELD" | grep -qx "$ROLE"; then
    echo "   = service account already has '$ROLE'"
    continue
  fi
  api GET "/$REALM/clients/$RM_CID/roles/$ROLE"
  expect 200 "Looking up role '$ROLE'"
  REP="$(printf '%s' "$API_BODY" | jq -c 'select(.id != null) | {id, name}' 2>/dev/null | tr -d '\r' || true)"
  [ -n "$REP" ] || die "Role '$ROLE' returned HTTP 200 but no usable id"
  TO_ADD="$(jq -c --argjson r "$REP" '. + [$r]' <<<"$TO_ADD")"
done

if [ "$TO_ADD" != "[]" ]; then
  api POST "/$REALM/users/$SA_USER_ID/role-mappings/clients/$RM_CID" "$TO_ADD"
  expect 204 "Assigning roles to the service account"
  echo ">> Assigned: $(jq -r '[.[].name] | join(", ")' <<<"$TO_ADD")"
fi

# ---------------------------------------------------------------------------
# 4. Secret
# ---------------------------------------------------------------------------
if [ "$ROTATE_SECRET" = "true" ]; then
  api POST "/$REALM/clients/$CID/client-secret"
  expect 200 "Rotating the client secret"
  echo ">> Secret ROTATED -- every runner holding the old one now fails with invalid_client."
else
  api GET "/$REALM/clients/$CID/client-secret"
  expect 200 "Reading the client secret"
fi
SECRET="$(body_get '.value // empty')"
[ -n "$SECRET" ] || die "Client secret came back empty -- is the client public?"

# ---------------------------------------------------------------------------
# 5. Prove it works. A created client is not a usable credential: verify it can
#    get a token AND read the realm, which is the first thing the provider does.
# ---------------------------------------------------------------------------
echo ">> Verifying the provisioner credential end-to-end ..."
PROV_RESP="$(printf '%s' "$SECRET" | curl -s -m 20 -X POST \
  "$KC_SERVER/realms/$REALM/protocol/openid-connect/token" \
  -d grant_type=client_credentials -d client_id="$CLIENT_ID" \
  --data-urlencode "client_secret@-" || true)"
PROV_TOKEN="$(printf '%s' "$PROV_RESP" | jq -r '.access_token // empty' 2>/dev/null | tr -d '\r')"
[ -n "$PROV_TOKEN" ] || die "client_credentials grant failed: $(printf '%s' "$PROV_RESP" | jq -r '.error_description // .error // "no detail"' 2>/dev/null)"
echo "   [ok]   client_credentials grant succeeds"

for CHECK in "" "/clients" "/client-scopes" "/groups" "/roles"; do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 20 \
    -H "Authorization: Bearer $PROV_TOKEN" "$KC_SERVER/admin/realms/$REALM$CHECK")"
  [ "$CODE" = "200" ] || die "GET /admin/realms/$REALM$CHECK -> $CODE. The service account is missing a realm-management role; tofu plan would fail partway through, not at startup."
  echo "   [ok]   GET /admin/realms/$REALM$CHECK -> 200"
done

# ---------------------------------------------------------------------------
# 6. Hand-off. Deliberately LAST: everything above is complete, so a missing az
#    CLI or a vault permission problem is a warning, not a reason to throw away a
#    successful bootstrap. The secret goes into Key Vault; it is printed only when
#    explicitly asked for and no vault was used.
# ---------------------------------------------------------------------------
STORED=false
if [ -n "$KEY_VAULT" ]; then
  if ! command -v az >/dev/null; then
    echo "   [warn] --key-vault given but the az CLI is not on PATH."
  elif printf '%s' "$SECRET" | az keyvault secret set --vault-name "$KEY_VAULT" \
         --name "terraform-provisioner--secret--clientSecret" --file /dev/stdin \
         --only-show-errors --output none; then
    STORED=true
    echo ">> Stored in Key Vault '$KEY_VAULT' as 'terraform-provisioner--secret--clientSecret'"
  else
    echo "   [warn] Could not write to Key Vault '$KEY_VAULT' (az login? Secrets Officer?)."
  fi
fi

echo
echo " Keycloak : $KC_SERVER"
echo " Realm    : $REALM"
echo " Client   : $CLIENT_ID"
echo " Roles    : $WANTED"
echo
if [ "$STORED" = "true" ]; then
  echo " Next, from the matching root:"
  echo "   export TF_VAR_provisioner_client_secret=\"\$(az keyvault secret show --vault-name $KEY_VAULT --name terraform-provisioner--secret--clientSecret --query value -o tsv)\""
  echo "   tofu init && tofu plan"
elif [ "$PRINT_SECRET" = "true" ]; then
  printf '%s\n' "$SECRET"
else
  echo " The secret was NOT stored or printed. Re-run with --key-vault <name> (preferred)"
  echo " or --print-secret, then export it as TF_VAR_provisioner_client_secret."
fi
echo ">> Done."
