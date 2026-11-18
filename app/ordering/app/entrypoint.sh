#!/bin/sh
# Writes assets/config.json for the SPA from environment variables, then execs nginx.
# Same contract as app/hr/entrypoint.sh: fail fast on a missing value, refuse values that would
# break the JSON, log key names only (the source printed the whole file), exec so nginx is PID 1.
set -eu

OUT_DIR=/tmp/runtime-config
OUT_FILE="$OUT_DIR/config.json"

for var in ACCESS_API_URL ORDERING_API_URL ORDERING_APP_URL IDENTITY_URL; do
  eval "value=\${$var:-}"
  if [ -z "$value" ]; then
    echo "entrypoint: $var is not set" >&2
    exit 1
  fi
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
  "accessApi": "${ACCESS_API_URL}",
  "orderingApi": "${ORDERING_API_URL}",
  "orderingApp": "${ORDERING_APP_URL}",
  "identityApi": "${IDENTITY_URL}"
}
EOF

echo "entrypoint: wrote $OUT_FILE (accessApi orderingApi orderingApp identityApi)"
exec "$@"
