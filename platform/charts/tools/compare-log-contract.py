#!/usr/bin/env python3
"""compare-log-contract.py <observability render> <observability-ingest render> <label>

The application log contract is parsed in two charts: observability's own Alloy
(observability.alloyConfig, alloyPipeline.parseLogContract) and the hub's
observability-ingest gateway (loki.process "set_tenant"). The LogQL rules in
observability-log-rules filter on the names they extract (http_status,
exception_type, the `level` label), so a field added to one parser and not the
other silently blinds the rules on half the tenants.

Reads the Alloy config out of each render (every ConfigMap data key ending in
.alloy), finds the stage.match that parses JSON lines (its selector matches a
leading `{`), and compares the field sets of its stage.json, stage.labels and
stage.structured_metadata. Exits 1 on any difference, or when either render has
no such stage.

No PyYAML: block scalars are cut out of the render by indentation, which is all
this needs.
"""
import re
import sys

STAGES = ("stage.json", "stage.labels", "stage.structured_metadata")
STRING = re.compile(r'"(?:\\.|[^"\\])*"')
FIELD = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*""\s*,?\s*$')
JSON_SELECTOR = "^\\\\\\\\{"  # as written in River: |~ \"^\\\\{\"


def alloy_configs(render):
    """Yield (where, text) for every `<key>.alloy: |` block scalar in the render."""
    lines = open(render, encoding="utf-8").read().splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)([A-Za-z0-9_.-]+\.alloy):\s*\|[-+]?\s*$", lines[i])
        if not m:
            i += 1
            continue
        indent, key = len(m.group(1)), m.group(2)
        body = []
        i += 1
        while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > indent):
            body.append(lines[i])
            i += 1
        yield key, "\n".join(body)


def contract_fields(text):
    """{stage: set(fields)} of the JSON-parsing stage.match, or None if absent."""
    stack = []  # (block name, is the contract match)
    fields = {s: set() for s in STAGES}
    found = False
    for raw in text.splitlines():
        line = STRING.sub('""', raw).split("//", 1)[0]
        name = line.strip().split(" ", 1)[0] if line.strip() else ""
        in_contract = any(c for _, c in stack)
        if in_contract and "selector" not in line:
            stage = next((n for n, _ in reversed(stack) if n in STAGES), None)
            m = FIELD.match(line)
            if stage and m:
                fields[stage].add(m.group(1))
        if "selector" in raw and JSON_SELECTOR in raw and stack and stack[-1][0] == "stage.match":
            stack[-1] = ("stage.match", True)
            found = True
        for _ in range(line.count("{")):
            stack.append((name, False))
        for _ in range(line.count("}")):
            if stack:
                stack.pop()
    return fields if found else None


def one(render):
    hits = [(where, f) for where, text in alloy_configs(render) if (f := contract_fields(text)) is not None]
    if len(hits) != 1:
        sys.exit(f"FAIL: expected exactly one log-contract stage.match in {render}, found {len(hits)}")
    return hits[0]


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    obs_where, obs = one(sys.argv[1])
    ing_where, ing = one(sys.argv[2])
    label = sys.argv[3]
    bad = False
    for stage in STAGES:
        if obs[stage] != ing[stage]:
            bad = True
            print(f"FAIL: {stage} differs ({label}): only in observability {sorted(obs[stage] - ing[stage])}, "
                  f"only in observability-ingest {sorted(ing[stage] - obs[stage])}", file=sys.stderr)
        else:
            print(f"   {stage}: {len(obs[stage])} fields, identical ({obs_where} vs {label} {ing_where})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
