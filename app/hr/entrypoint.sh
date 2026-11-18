#!/bin/sh
# Writes the SPA's runtime config (assets/config.json) from environment variables, then execs the
# container command (nginx). One image serves every environment; only the env differs.
#
# FIX compared with the source: the real script echoed every variable and then `cat` the whole file
# into the log "to verify". Nothing in this file is a secret today, but an entrypoint that prints its
# environment is one added variable away from printing one. It now logs the key NAMES it wrote and
# nothing else.
set -eu

OUT_DIR=/tmp/runtime-config
OUT_FILE="$OUT_DIR/config.json"

# Fail fast, naming the variable. The chart already `required`s every key; this is the second line of
# defence for `docker run` and for anyone deploying the image some other way. An empty value would
# otherwise leave the SPA on its baked localhost placeholders, which load fine and fail later.
for var in IDENTITY_URL IDENTITY_SCOPE IDENTITY_CLIENT IDENTITY_REDIRECT_URI API_URL \
           APP_PORTAL_PATH APP_ADMIN_PATH APP_ABSENCE_PATH APP_EMPLOYEE_BOOK_PATH; do
  eval "value=\${$var:-}"
  if [ -z "$value" ]; then
    echo "entrypoint: $var is not set" >&2
    exit 1
  fi
  # The values are written into a JSON string with a heredoc, not a JSON encoder (the image has no
  # jq). So refuse the two characters that could break out of the string instead of escaping them.
  case "$value" in
    *\"* | *\\*)
      echo "entrypoint: $var contains a quote or backslash, refusing to write it into JSON" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
cat > "$OUT_FILE" <<EOF
{
  "identityUrl": "${IDENTITY_URL}",
  "identityScope": "${IDENTITY_SCOPE}",
  "identityClient": "${IDENTITY_CLIENT}",
  "identityRedirectUri": "${IDENTITY_REDIRECT_URI}",
  "apiUrl": "${API_URL}",
  "appPortalPath": "${APP_PORTAL_PATH}",
  "appAdminPath": "${APP_ADMIN_PATH}",
  "appAbsencePath": "${APP_ABSENCE_PATH}",
  "appEmployeeBookPath": "${APP_EMPLOYEE_BOOK_PATH}"
}
EOF

echo "entrypoint: wrote $OUT_FILE (identityUrl identityScope identityClient identityRedirectUri apiUrl appPortalPath appAdminPath appAbsencePath appEmployeeBookPath)"

# exec: nginx becomes PID 1 and receives SIGTERM from the kubelet directly. Without exec, the shell
# would be PID 1, would not forward the signal, and every pod stop would wait out the full grace
# period and end in SIGKILL.
exec "$@"
