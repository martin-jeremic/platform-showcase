#!/usr/bin/env python3
"""render-gates.py <chart> <rendered.yaml>

Gates on a chart's RENDERED output -- what Argo CD would apply, not what the values
files say. Every gate is a defect that renders fine and fails (or leaks) at runtime.
No PyYAML: the CI agent's python3 is not guaranteed to have it, and every check
here is about the shape of one document, which splitting on `---` gives.

  1. no PersistentVolume at all, and never a hostPath-backed one. A chart that
     templates a PV pins data to one node (the fork's observability chart rendered
     hostPath PVs with nodeAffinity to a developer laptop's hostname; on AKS the
     PVCs hung Pending forever). NOT "hostPath appears in the output": the CSI node
     plugin and the log collector legitimately mount hostPath VOLUMES.
  2. no HTTPRoute claims PathPrefix `/` -- reserved for the application UI.
  3. no route binds to every listener: an HTTPRoute parentRef on the platform
     Gateway without sectionName also attaches to plaintext `web`.
  4. no plausible literal password, and no unfilled REPLACE_WITH_ placeholder (a
     placeholder that RENDERS is a value some component will send somewhere: two
     workload-identity client IDs once reached Entra as the literal string and the
     pods crash-looped for hours).
  5. no image without a tag, or tagged `latest`.
  6. no `example-internal` string -- the generic stand-in for "an internal
     hostname or name that must never reach a public render".
  7. production floor, per workload: every Deployment / StatefulSet / DaemonSet
     carries priorityClassName and resource limits, unless listed as a documented
     exception below.

Exit 1 on any failure; prints one line per finding.
"""
import re
import sys

# Documented exceptions to gate 7 (chart -> reason). Anything else must comply.
NO_PRIORITY = {
    "cluster-test": "a diagnostic that SHOULD be evicted first",
    "postgres-exporter": "nothing depends on it; losing it costs a dashboard gap",
    "azurite": "test-data emulator, never production",
    "headlamp": "a UI, evicted before platform services",
}
# (chart, kind) pairs whose limits are deliberately left to upstream defaults; the
# chart's values say why next to the setting. Empty today -- every workload sets
# its own.
NO_LIMITS_KINDS = set()

PASSWORD = re.compile(r"""(?im)^[ \t]*[A-Za-z0-9_.-]*password[A-Za-z0-9_.-]*:[ \t]+["']?([^"'\s{][^"'\s]{5,})""")
PASSWORD_OK = re.compile(r"(?i)secretKeyRef|existingSecret|passwordSecret|_FILE$|\$\(|^/|\.yaml$|-password$|Password$")


def docs(text):
    for d in re.split(r"(?m)^---\s*$", text):
        if d.strip():
            yield d


def kind_of(d):
    m = re.search(r"(?m)^kind:\s*(\S+)", d)
    return m.group(1) if m else ""


def name_of(d):
    m = re.search(r"(?m)^metadata:\n(?:\s+.*\n)*?\s+name:\s*(\S+)", d)
    return m.group(1) if m else "?"


def main(chart, path):
    text = open(path, encoding="utf-8").read()
    bad = []
    for d in docs(text):
        k, n = kind_of(d), name_of(d)
        where = f"{k}/{n}"
        if k == "PersistentVolume":
            bad.append(f"{where}: templates a PersistentVolume{' (hostPath!)' if 'hostPath:' in d else ''} -- storage must be dynamically provisioned")
        if k == "HTTPRoute":
            # Comments may name the Gateway too (and do, to explain a fix).
            d = re.sub(r"(?m)^\s*#.*\n", "", d)
            if re.search(r"type:\s*PathPrefix\s*\n\s*value:\s*[\"']?/[\"']?\s*$", d, re.M):
                bad.append(f"{where}: claims PathPrefix / (reserved for the application UI)")
            for ref in re.findall(r"(?ms)^\s*parentRefs:\n(.*?)(?=^\s*(?:hostnames|rules):)", d):
                for entry in re.split(r"(?m)^\s*-\s", ref):
                    if "traefik-gateway" in entry and "sectionName" not in entry:
                        bad.append(f"{where}: parentRef without sectionName binds to the plaintext listener too")
        # CRD schemas describe password FIELDS; they hold no values.
        for m in ([] if k == "CustomResourceDefinition" else PASSWORD.finditer(d)):
            line = m.group(0).strip()
            if not PASSWORD_OK.search(m.group(1)) and not PASSWORD_OK.search(line):
                bad.append(f"{where}: literal password? -> {line[:80]}")
        if "REPLACE_WITH_" in d:
            bad.append(f"{where}: unfilled REPLACE_WITH_ placeholder")
        if "example-internal" in d:
            bad.append(f"{where}: internal-only name in the render")
        for img in re.findall(r"(?m)^\s*image:\s*[\"']?([^\"'\s]+)", d):
            ref = img.split("@")[0]
            last = ref.rsplit("/", 1)[-1]
            if "@sha256:" in img:
                continue
            if ":" not in last or last.endswith(":latest"):
                bad.append(f"{where}: image {img} is untagged or :latest")
        if k in ("Deployment", "StatefulSet", "DaemonSet"):
            if chart not in NO_PRIORITY and "priorityClassName:" not in d:
                bad.append(f"{where}: no priorityClassName (production floor)")
            if (chart, k) not in NO_LIMITS_KINDS and "limits:" not in d:
                bad.append(f"{where}: no resource limits (production floor)")
    for b in bad:
        print(f"FAIL {chart}: {b}")
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
