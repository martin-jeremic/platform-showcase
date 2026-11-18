#!/usr/bin/env python3
"""Validate Grafana dashboard JSON before it can reach a cluster.

Every check here is a failure that is SILENT at deploy time: the ConfigMap
applies, the dashboard appears in its folder, and it is useless. Argo cannot
see any of them -- the JSON is opaque to it.

The same checks run on both sides of the dashboard split: chart-owned dashboards
here, cluster-owned ones in the gitops repo. Conventions: a `datasource` variable
instead of literal Prometheus uids, and every $variable a query uses must be
defined -- a ported query that filters on $cluster without a cluster variable
renders "No data".

Usage: python3 tools/validate-dashboards.py observability/dashboards
"""
import glob
import json
import os
import re
import sys

# Datasource uids that exist on EVERY cluster this chart serves:
#   prometheus  kube-prometheus-stack sidecar default
#   loki        additionalDataSources (every cluster values file restates it)
# NOT tempo: clusters with components.tempo: false have no such datasource, so a
# panel pinned to tempo would be broken there.
KNOWN_UIDS = {"prometheus", "loki", "-- Grafana --"}  # the last: Grafana's built-in annotations source

# Grafana's own variables, always defined.
BUILTIN = re.compile(r"^__")
VAR_REF = re.compile(r"\$\{([A-Za-z0-9_]+)(?::[^}]*)?\}|\$([A-Za-z_][A-Za-z0-9_]*)")


def walk(o, fn):
    if isinstance(o, dict):
        fn(o)
        for v in o.values():
            walk(v, fn)
    elif isinstance(o, list):
        for v in o:
            walk(v, fn)


def check(path, d, raw, uids, rel):
    msgs = []
    uid = d.get("uid")
    if not uid:
        msgs.append("no top-level uid")
    elif uid in uids:
        msgs.append(f"uid '{uid}' already used by {uids[uid]}")
    else:
        uids[uid] = rel
    if not d.get("title"):
        msgs.append("no title")

    # File provisioning does not resolve __inputs -- only the UI import wizard
    # does. A grafana.com export left as-is renders every panel as
    # "Datasource not found".
    if "__inputs" in raw:
        msgs.append("contains __inputs (file provisioning cannot resolve it)")
    if "${DS_" in raw:
        msgs.append("contains an unresolved ${DS_*} placeholder")

    variables = {v.get("name"): v for v in d.get("templating", {}).get("list", [])}

    bad = set()

    def ds(o):
        ref = o.get("datasource")
        if isinstance(ref, dict) and "uid" in ref:
            u = ref["uid"]
            if u in ("${datasource}", "$datasource"):
                v = variables.get("datasource")
                if not v or v.get("type") != "datasource":
                    bad.add(f"{u} without a `datasource` variable of type datasource")
            elif u not in KNOWN_UIDS:
                bad.add(u)
        elif isinstance(ref, str):
            bad.add(f"{ref} (string form -- use {{type, uid}})")

    walk(d, ds)
    if bad:
        msgs.append("unknown/invalid datasource: " + ", ".join(sorted(bad)))

    undefined = set()

    def refs(o):
        texts = []
        for k in ("expr", "query", "definition", "legendFormat"):
            v = o.get(k)
            if isinstance(v, str):
                texts.append(v)
            elif isinstance(v, dict) and isinstance(v.get("query"), str):
                texts.append(v["query"])
        for t in texts:
            for m in VAR_REF.finditer(t):
                name = m.group(1) or m.group(2)
                if not BUILTIN.match(name) and name not in variables:
                    undefined.add(name)

    walk(d.get("panels", []), refs)
    walk(d.get("templating", {}), refs)
    if undefined:
        msgs.append("uses undefined variable(s): " + ", ".join("$" + n for n in sorted(undefined)))

    panels = [p for p in d.get("panels", []) if p.get("type") != "row"]
    nested = [p for r in d.get("panels", []) for p in r.get("panels", [])]
    if not panels and not nested:
        msgs.append("no panels")
    return uid, msgs, len(panels) + len(nested)


def main(root):
    files = sorted(glob.glob(os.path.join(root, "*", "*.json")))
    stray = sorted(glob.glob(os.path.join(root, "*.json")))
    fail = 0
    if stray:
        # templates/dashboards.yaml only globs dashboards/<Folder>/*.json, so a
        # file at the top level would never be deployed.
        for f in stray:
            print(f"FAIL {os.path.relpath(f, root)}: not inside a folder -- it would never be deployed")
        fail = 1
    if not files:
        print(f"FAIL: no dashboard JSON under {root}/<Folder>/")
        return 1
    uids = {}
    for f in files:
        rel = os.path.relpath(f, root).replace(os.sep, "/")
        raw = open(f, encoding="utf-8").read()
        try:
            d = json.loads(raw)
        except Exception as e:  # noqa: BLE001 -- report and continue
            print(f"FAIL {rel}: invalid JSON: {e}")
            fail = 1
            continue
        uid, msgs, n = check(f, d, raw, uids, rel)
        if msgs:
            for m in msgs:
                print(f"FAIL {rel}: {m}")
            fail = 1
        else:
            print(f"PASS {rel:42s} uid={uid:22s} panels={n}")
    print("---")
    print(f"{len(files)} dashboards checked, {len(uids)} unique uids")
    print("ALL DASHBOARD CHECKS PASS" if not fail else "DASHBOARD CHECK FAILURES")
    return fail


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "observability/dashboards"))
