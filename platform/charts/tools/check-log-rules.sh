#!/usr/bin/env bash
# check-log-rules.sh -- gates for the LogQL rules (observability-log-rules/log-rules/).
#
# promtool cannot parse LogQL, so the PrometheusRule gates do not cover these.
# Three checks, each for a failure that is silent at deploy time (the ConfigMap
# applies, the ruler loads, and the alert never fires):
#
#   1. lokitool rules lint + check, at the Loki version the observability chart
#      renders -- a rule is parsed by the version of the parser that will evaluate
#      it. A Loki release without a lokitool asset fails here rather than skipping.
#   2. Every log-contract field a rule filters on (`| <field>=...`) is extracted by
#      the Alloy contract stage (stage.labels / stage.structured_metadata in the
#      rendered config.alloy). A rule on a field the collector never sets matches
#      nothing, forever.
#   3. The ingest-rate dashboard draws the same threshold as PlatformInboundRateHigh
#      (tools/check-dashboard-threshold.py).
#
# Run from platform/charts/. Needs helm, curl, python3; the observability
# dependencies must be built (tools/check-platform.sh does that first).
set -euo pipefail

cd "$(dirname "$0")/.."
OBS=observability
RULES_CHART=observability-log-rules
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# A python that actually runs (on Windows `python3` can be the Store stub).
PY=${PYTHON:-}
if [ -z "$PY" ]; then
  for c in python3 python; do
    if "$c" -c 'import sys' >/dev/null 2>&1; then PY=$c; break; fi
  done
fi
[ -n "$PY" ] || { echo "FAIL: no working python3/python on PATH"; exit 1; }

shopt -s nullglob
rules=("$RULES_CHART"/log-rules/*.yaml)
[ ${#rules[@]} -gt 0 ] || { echo "FAIL: no $RULES_CHART/log-rules/*.yaml"; exit 1; }

printf 'alloyPipeline:\n  parseLogContract: true\n' >"$WORK/contract.yaml"
helm template "$OBS" "$OBS" -n observability --api-versions monitoring.coreos.com/v1 \
  -f "$OBS/ci/island-values.yaml" -f "$WORK/contract.yaml" >"$WORK/render.yaml"

# ---- 1. lokitool ------------------------------------------------------------
if [ "${SKIP_LOKITOOL:-0}" = 1 ]; then
  echo "SKIP lokitool (SKIP_LOKITOOL=1)"
else
  loki_version=$(grep -oE 'image: "?[^" ]*grafana/loki:[0-9]+\.[0-9]+\.[0-9]+' "$WORK/render.yaml" | head -1 | sed 's/.*://')
  [ -n "$loki_version" ] || { echo "FAIL: no grafana/loki image in the render"; exit 1; }
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) lt_asset=lokitool-windows-amd64.exe ;; *) lt_asset=lokitool-linux-amd64 ;; esac
  curl -fsSL -o "$WORK/lokitool.zip" \
    "https://github.com/grafana/loki/releases/download/v$loki_version/$lt_asset.zip" \
    || { echo "FAIL: cannot fetch lokitool $loki_version ($lt_asset.zip) from the Loki release"; exit 1; }
  "$PY" -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$WORK/lokitool.zip" "$WORK/lokitool"
  lokitool="$WORK/lokitool/$lt_asset"
  chmod +x "$lokitool"
  echo "lokitool $loki_version"
  "$lokitool" rules lint --dry-run "${rules[@]}"
  "$lokitool" rules check "${rules[@]}"
fi

# ---- 2. rule fields vs the Alloy contract stage -----------------------------
"$PY" - "$WORK/render.yaml" "${rules[@]}" <<'PY'
import re, sys
render, rule_files = sys.argv[1], sys.argv[2:]
text = open(render, encoding="utf-8").read()
blocks = re.findall(r"stage\.(?:labels|structured_metadata)\s*\{\s*values\s*=\s*\{(.*?)\}", text, re.S)
if not blocks:
    sys.exit("FAIL: no stage.labels / stage.structured_metadata in the rendered Alloy config")
extracted = {n for b in blocks for n in re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", b, re.M)}
used = {}
for f in rule_files:
    for expr in re.findall(r"expr:\s*\|?\s*\n?(.*?)(?=\n\s*(?:for|labels|annotations):)", open(f, encoding="utf-8").read(), re.S):
        # A label filter after a pipe: `| http_status=~"5.."`. `|=` / `|~` are line
        # filters (no identifier after the pipe) and do not match.
        for field in re.findall(r"\|\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:!=|=~|!~|=|>|<)", expr):
            used.setdefault(field, set()).add(f)
missing = sorted(set(used) - extracted)
if missing:
    for m in missing:
        print(f"FAIL: {', '.join(sorted(used[m]))} filters on `{m}`, which the Alloy contract stage does not extract")
    sys.exit(1)
print(f"PASS rule fields {sorted(used)} are all extracted by the Alloy contract stage")
PY

# ---- 3. dashboard threshold -------------------------------------------------
"$PY" tools/check-dashboard-threshold.py "$RULES_CHART/log-rules/ingest-rate.yaml" "$OBS/dashboards/Product/ingest-rate.json"
