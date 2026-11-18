#!/usr/bin/env python3
"""List, for every object that has a `helm` field manager, the field paths owned by helm and by
NO other manager. Those are exactly the fields a server-side apply by the new owner will never
remove (and that recreating the object will drop), so anything the app still needs among them
must be added to the chart BEFORE the takeover is finished.

Reads `kubectl get ... -o json --show-managed-fields` output (a List) on stdin:

  kubectl -n <namespace> get deploy,svc,sa,hpa,httproute,secretproviderclass \
    --show-managed-fields -o json | python bootstrap/helm-only-fields.py
"""
import json
import sys


def leaves(node, prefix=()):
    """Flatten a fieldsV1 tree into leaf paths ('.' marks 'this node itself')."""
    out = set()
    for key, child in node.items():
        if key == ".":
            out.add(prefix)
            continue
        if child:
            out |= leaves(child, prefix + (key,))
        else:
            out.add(prefix + (key,))
    return out


def readable(path):
    parts = []
    for p in path:
        if p.startswith("f:"):
            parts.append(p[2:])
        elif p.startswith("k:"):
            parts.append("[" + ",".join(f"{k}={v}" for k, v in json.loads(p[2:]).items()) + "]")
        elif p.startswith("v:"):
            parts.append("[" + p[2:] + "]")
        else:
            parts.append(p)
    return ".".join(parts).replace(".[", "[")


def main():
    doc = json.load(sys.stdin)
    for obj in doc.get("items", []):
        mf = obj["metadata"].get("managedFields") or []
        helm = [m for m in mf if m["manager"] == "helm"]
        if not helm:
            continue
        helm_paths = set().union(*(leaves(m.get("fieldsV1", {})) for m in helm))
        others = set().union(set(), *(leaves(m.get("fieldsV1", {})) for m in mf if m["manager"] != "helm"))
        # A helm leaf survives if another manager owns the same path or anything below it.
        only = sorted(p for p in helm_paths if not any(o[:len(p)] == p for o in others))
        managers = ", ".join(sorted({f"{m['manager']}/{m['operation']}" for m in mf}))
        print(f"{obj['kind']}/{obj['metadata']['name']}  [{managers}]")
        for p in only:
            print("   helm-only: " + readable(p))
        if not only:
            print("   helm-only: (none)")


if __name__ == "__main__":
    main()
