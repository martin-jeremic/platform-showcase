#!/usr/bin/env bash
# validate-all.sh: every check this repository can run on a workstation.
#
# It finds charts, stacks and scripts by walking the tree, so a new chart or stack is
# checked without editing this file. Tools that are not installed are reported as
# SKIPPED, never as passed: a check that did not run must not look like a green one.
#
# Usage: tools/validate-all.sh            (from anywhere)
#        OFFLINE=1 tools/validate-all.sh  (do not download Helm dependencies or providers)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
FAILED=0; SKIPPED=0
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok    %s\n' "$*"; }
bad()  { printf '    FAIL  %s\n' "$*" >&2; FAILED=$((FAILED + 1)); }
skip() { printf '    skip  %s\n' "$*"; SKIPPED=$((SKIPPED + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }

# python3 on Linux agents; on Windows `python3` can be a Store stub that prints nothing.
PYTHON=python3; "$PYTHON" -c 'import sys' >/dev/null 2>&1 || PYTHON=python

# ── 1. Hygiene: no secrets, only placeholder identifiers ─────────────────────────
step "Secrets and identifiers"
if "$PYTHON" tools/scan-secrets.py "$ROOT"; then ok "scan-secrets"; else bad "scan-secrets"; fi

# ── 2. Helm charts ──────────────────────────────────────────────────────────────
# Service charts only. Platform charts are rendered by platform/charts/tools/check-platform.sh
# (step below), which knows each chart's target namespace (several charts refuse to render in
# the wrong one, on purpose), passes the CRD API versions, runs the rendered-output gates and the
# refusal tests. Rendering them here as well, without that context, would only produce false failures.
step "Service charts (lint + render with every ci/*.yaml)"
if have helm; then
  while IFS= read -r chartfile; do
    dir=$(dirname "$chartfile")
    rel=${dir#"$ROOT"/}
    # Wrapper charts need their upstream subcharts. They are rebuilt from Chart.lock, never committed.
    # `helm dependency build` refuses repositories it has not been told about, so register the
    # ones Chart.yaml names first (idempotent: --force-update).
    if grep -q '^dependencies:' "$chartfile" && [ ! -d "$dir/charts" ]; then
      if [ "${OFFLINE:-0}" = 1 ]; then skip "$rel (OFFLINE=1, has dependencies)"; continue; fi
      i=0
      for url in $(awk '/repository:/{gsub(/"/,"",$2); print $2}' "$chartfile" | grep '^https://' | sort -u); do
        i=$((i + 1)); helm repo add "$(basename "$dir")-dep$i" "$url" --force-update >/dev/null 2>&1
      done
      if ! helm dependency build "$dir" >/dev/null 2>&1; then
        skip "$rel (dependencies could not be downloaded)"; continue
      fi
    fi
    valuesets=()
    for v in "$dir"/ci/*.yaml; do [ -f "$v" ] && valuesets+=("$v"); done
    [ ${#valuesets[@]} -eq 0 ] && valuesets=("")
    for v in "${valuesets[@]}"; do
      args=(); [ -n "$v" ] && args=(-f "$v")
      label="$rel${v:+ [$(basename "$v")]}"
      if helm lint "$dir" "${args[@]}" >/dev/null 2>&1 && helm template ci "$dir" "${args[@]}" >/dev/null 2>&1; then
        ok "$label"
      else
        bad "$label"; helm template ci "$dir" "${args[@]}" 2>&1 | tail -5 | sed 's/^/          /' >&2
      fi
    done
  done < <(find "$ROOT" -name Chart.yaml -not -path '*/.git/*' -not -path "$ROOT/platform/charts/*" | sort)
else
  skip "helm not installed"
fi

# Folder-specific suites (refusal tests, perturbation checks, catalog validation).
step "Folder test suites"
for suite in platform/charts/tools/check-platform.sh; do
  if [ -x "$suite" ] || [ -f "$suite" ]; then
    if bash "$suite" >/dev/null 2>&1; then ok "$suite"; else bad "$suite (run it directly for details)"; fi
  fi
done
for comp in gitops/platform/hub/platform/component.sh gitops/platform/island/aks-product-a-prod/platform/component.sh; do
  [ -f "$comp" ] || continue
  if sh "$comp" validate >/dev/null 2>&1; then ok "$comp validate"; else bad "$comp validate"; fi
done

# ── 3. OpenTofu ─────────────────────────────────────────────────────────────────
step "OpenTofu"
if have tofu; then
  if tofu fmt -check -recursive infra >/dev/null; then ok "tofu fmt"; else bad "tofu fmt (run: tofu fmt -recursive infra)"; fi
  if [ "${OFFLINE:-0}" = 1 ]; then
    skip "tofu validate (OFFLINE=1)"
  else
    # A stack is a directory that declares a terraform{} block.
    while IFS= read -r stack; do
      rel=${stack#"$ROOT"/}
      if (cd "$stack" && tofu init -backend=false -input=false >/dev/null 2>&1 && tofu validate -no-color >/dev/null 2>&1); then
        ok "$rel"
      else
        bad "$rel (cd $rel && tofu init -backend=false && tofu validate)"
      fi
    done < <(grep -l '^terraform {' -r infra --include='*.tf' | xargs -n1 dirname | sort -u | sed "s|^|$ROOT/|")
  fi
else
  skip "tofu not installed"
fi

# ── 4. Scripts and data files ───────────────────────────────────────────────────
step "Shell, Python, JSON"
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then :; else bad "bash -n ${f#"$ROOT"/}"; fi
done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*' -not -path '*/node_modules/*')
ok "shell syntax"
while IFS= read -r f; do
  if "$PYTHON" -m py_compile "$f" 2>/dev/null; then :; else bad "py_compile ${f#"$ROOT"/}"; fi
done < <(find "$ROOT" -name '*.py' -not -path '*/.git/*')
ok "python compile"
while IFS= read -r f; do
  if "$PYTHON" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$f" 2>/dev/null; then :; else bad "json ${f#"$ROOT"/}"; fi
done < <(find "$ROOT" -name '*.json' -not -path '*/.git/*' -not -path '*/node_modules/*')
ok "json parse"

# ── 5. Alert rules ──────────────────────────────────────────────────────────────
step "Alert-rule unit tests"
tests=$(find platform/charts -path '*/rules/tests/*.yaml' 2>/dev/null)
if [ -z "$tests" ]; then
  skip "no rule tests found"
elif have promtool; then
  for t in $tests; do
    if (cd "$(dirname "$t")" && promtool test rules "$(basename "$t")" >/dev/null); then ok "$t"; else bad "$t"; fi
  done
elif have docker && docker info >/dev/null 2>&1; then
  export MSYS_NO_PATHCONV=1
  for t in $tests; do
    d="$ROOT/$(dirname "$(dirname "$t")")"; have cygpath && d=$(cygpath -w "$d")
    if docker run --rm -v "$d:/rules:ro" -w /rules/tests --entrypoint promtool quay.io/prometheus/prometheus:v3.5.0 \
         test rules "$(basename "$t")" >/dev/null; then ok "$t"; else bad "$t"; fi
  done
else
  skip "promtool and a running Docker daemon are both unavailable: rule tests NOT run"
fi

echo
echo "validate-all: $FAILED failed, $SKIPPED skipped"
[ "$FAILED" -eq 0 ]
