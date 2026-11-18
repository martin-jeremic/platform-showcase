#!/usr/bin/env python3
"""check-dashboard-threshold.py <log-rule file> <dashboard json>

The "Product A / Ingest rate" dashboard draws the threshold of
PlatformInboundRateHigh as a line. Grafana cannot read it from the rule, so the
number is written in two files -- which may live in two repos:

  rule       observability-log-rules/log-rules/ingest-rate.yaml   (this repo)
  dashboard  observability/dashboards/Product/ingest-rate.json   (this repo), or a
             cluster-owned copy in the gitops repo's dashboards/ tree

Both pipelines run this: the chart pipeline on a rule change, the gitops pipeline
on a dashboard change -- against the rule AT THE CHART TAG the descriptor pins, so
a dashboard cannot land ahead of the chart version that ships its rule. Exits 1
when the drawn value differs from the rule's, or when either side cannot be read.

No PyYAML: the hosted agent's python3 is not guaranteed to have it, and the rule
file is a fixed shape (`- alert: <name>` followed by `expr: |`).
"""
import json
import re
import sys

ALERT = "PlatformInboundRateHigh"


def rule_threshold(path):
    text = open(path, encoding="utf-8").read()
    m = re.search(
        r"-\s*alert:\s*" + ALERT + r"\s*\n\s*expr:\s*\|\s*\n(.*?)\n\s*(?:for|labels|annotations):",
        text,
        re.S,
    )
    if not m:
        sys.exit(f"FAIL: {ALERT} with a block `expr: |` not found in {path}")
    t = re.search(r"\)\s*>\s*([0-9.]+)\s*$", m.group(1).strip())
    if not t:
        sys.exit(f"FAIL: cannot read the threshold of {ALERT} (expected the expression to end in ') > N')")
    return float(t.group(1))


def drawn_thresholds(path):
    drawn = []

    def walk(o):
        if isinstance(o, dict):
            t = o.get("thresholds")
            if isinstance(t, dict):
                drawn.extend(s["value"] for s in t.get("steps", []) if s.get("value") is not None)
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(json.load(open(path, encoding="utf-8")))
    return drawn


def main(rules, dash):
    want = rule_threshold(rules)
    drawn = drawn_thresholds(dash)
    if not drawn:
        sys.exit(f"FAIL: {dash} draws no threshold")
    bad = [v for v in drawn if float(v) != want]
    if bad:
        sys.exit(f"FAIL: {dash} draws threshold(s) {bad}, but {ALERT} fires above {want:g}")
    print(f"PASS {ALERT}: fires above {want:g}; the dashboard draws the same in {len(drawn)} place(s)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
