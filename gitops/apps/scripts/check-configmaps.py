#!/usr/bin/env python3
"""Verify that apps/<svc>/<env>/values.yaml is a COMPLETE source of truth for each environment.

For every app/env with a release.yaml, pull the pinned chart from the registry, render it with
the env's values.yaml + image.yaml (exactly what the ApplicationSet passes), and check:

  0. env-owned keys are stated          -> replicaCount, probes, scheduling, ... must be set in
                                           GitOps wherever the chart declares them, never inherited
                                           from the chart default
  1. no ConfigMap value is empty        -> an empty value means the app falls back to a chart or
                                           code default nobody reviewed
  2. the key SET matches across envs    -> a key present in demo but not prod is drift
  3. no value is Base64-encoded JSON    -> config must be readable in `kubectl get cm`; an encoded
                                           value also crash-loops any service whose binder expects
                                           plain JSON
  4. no ConfigMap key is inherited      -> a key that renders the same with and without the env's
                                           config block is chart-owned, not GitOps-owned, even if
                                           it is non-empty (the perturbation probe)

Plus, independent of rendering, pin consistency: paired apps (a service and its migration Job
chart) must carry the same chart.version and image.digest in every environment.

Exceptions live in scripts/configmap-exceptions.yaml; every entry there must say WHY.

Usage:  python scripts/check-configmaps.py [--app NAME] [--offline] [--charts-dir DIR]
  --offline     never `helm pull`; use charts already in the cache directory (skip the rest)
  --charts-dir  render from unpacked chart directories DIR/<app>/ instead of the registry
                (validates the GitOps values against charts in a working tree)
Exit code 1 if any check fails.
"""
import argparse
import base64
import glob
import os
import re
import subprocess
import sys
import tarfile
import tempfile

import yaml

# Windows build agents default to cp1252; force UTF-8 so a finding never dies on an em dash.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8")
    except Exception:
        pass

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(tempfile.gettempdir(), "product-a-chart-cache")
ENVS = ["stage", "demo", "prod"]          # dev is record-only (image.yaml), never rendered by Argo
REGISTRY = "oci://productacr.azurecr.io/helm"

# Top-level chart values that are per-environment decisions and must be stated in GitOps rather
# than inherited. replicaCount above all: every chart defaulted it to 1, so prod ran a single pod
# of everything and nothing in this repo said so. A key is only required where the chart declares
# it, so a chart without e.g. startupProbe is not penalised.
OWNED_KEYS = [
    "replicaCount",           # horizontal scaling (while autoscaling.enabled is false)
    "autoscaling",            # horizontal scaling (HPA)
    "resources",              # vertical scaling: requests/limits
    "startupProbe",           # health
    "readinessProbe",         # health
    "livenessProbe",          # health
    "nodeSelector",           # scheduling
    "tolerations",            # scheduling
    "affinity",               # scheduling
    "workloadIdentity",       # which identity the pod runs as: per env by definition
    "config",                 # ConfigMap source
    "otel",                   # telemetry endpoint: per cluster
    "seedOnDeploy",           # reference-data seed Jobs on every deploy
    "cronDefaults",           # CronJob concurrency / deadlines / history
    "migrationJob",           # whether and how the schema Job runs
]

_CHART_VALUES = {}


def load_yaml(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def load_exceptions():
    return load_yaml(os.path.join(REPO, "scripts", "configmap-exceptions.yaml")) or {}


def chart_version(app, env):
    doc = load_yaml(os.path.join(REPO, "apps", app, env, "release.yaml"))
    return ((doc or {}).get("chart") or {}).get("version") or None


def image_digest(app, env):
    doc = load_yaml(os.path.join(REPO, "apps", app, env, "image.yaml"))
    return ((doc or {}).get("image") or {}).get("digest") or None


def fetch_chart(app, version, offline, charts_dir):
    """Path to something `helm template` accepts (a .tgz or a chart directory), or None."""
    if charts_dir:
        d = os.path.join(charts_dir, app)
        return d if os.path.isfile(os.path.join(d, "Chart.yaml")) else None
    tgz = os.path.join(CACHE, f"{app}-{version}.tgz")
    if os.path.exists(tgz):
        return tgz
    if offline:
        return None
    os.makedirs(CACHE, exist_ok=True)
    r = subprocess.run(["helm", "pull", f"{REGISTRY}/{app}", "--version", version, "-d", CACHE],
                       capture_output=True, text=True)
    return tgz if r.returncode == 0 and os.path.exists(tgz) else None


def chart_declares(chart, key):
    """True if the chart's own values.yaml has this top-level key (so a template reads it)."""
    cached = _CHART_VALUES.get(chart)
    if cached is None:
        cached = {}
        try:
            if os.path.isdir(chart):
                cached = load_yaml(os.path.join(chart, "values.yaml")) or {}
            else:
                with tarfile.open(chart) as tf:
                    for m in tf.getmembers():
                        if m.name.count("/") == 1 and m.name.endswith("/values.yaml"):
                            cached = yaml.safe_load(tf.extractfile(m).read().decode("utf-8")) or {}
                            break
        except Exception:
            pass
        _CHART_VALUES[chart] = cached
    return key in cached


def env_values(app, env):
    return load_yaml(os.path.join(REPO, "apps", app, env, "values.yaml")) or {}


def _render(app, chart, value_files):
    args = ["helm", "template", app, chart]
    for p in value_files:
        args += ["-f", p]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        return None, r.stderr.strip().splitlines()[:2]
    data = {}
    for doc in yaml.safe_load_all(r.stdout):
        if doc and doc.get("kind") == "ConfigMap":
            data.update(doc.get("data") or {})
    return data, None


def render_configmaps(app, env, chart):
    """{key: value} merged across every ConfigMap the chart renders for this env."""
    files = [os.path.join(REPO, "apps", app, env, n) for n in ("values.yaml", "image.yaml")]
    return _render(app, chart, [p for p in files if os.path.exists(p)])


def _perturb(node):
    """Recursively change every scalar leaf to something different but of the same type."""
    if isinstance(node, dict):
        return {k: _perturb(v) for k, v in node.items()}
    if isinstance(node, list):
        return [_perturb(v) for v in node]
    if isinstance(node, bool):
        return not node
    if isinstance(node, (int, float)):
        return node + 1
    if node is None:
        return "__PROBE__"
    return str(node) + "__PROBE__"


def render_with_perturbed_config(app, env, chart):
    """Render the env's values with every leaf of its config block altered.

    A ConfigMap key whose value is UNCHANGED by that perturbation is not driven by this env's
    values file at all: it comes from the chart default. That is how a whole service's ConfigMap
    once stayed chart-owned while every other check passed.

    Perturbing (rather than deleting) the block is what makes this precise: a key the env file
    legitimately owns but happens to set to the same string as the chart default still moves, so
    it is not reported. Ownership means the key is STATED here, not that its value differs.
    """
    vals = env_values(app, env)
    if "config" not in vals:
        return None  # nothing stated at all; check 0 reports that
    vals["config"] = _perturb(vals["config"])
    fd, tmp = tempfile.mkstemp(suffix=".yaml")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            yaml.safe_dump(vals, f)
        files = [tmp]
        img = os.path.join(REPO, "apps", app, env, "image.yaml")
        if os.path.exists(img):
            files.append(img)
        data, err = _render(app, chart, files)
        return None if err else data
    finally:
        os.unlink(tmp)


def decodes_to_json(value):
    """True if the value is Base64 that decodes to JSON: config hidden behind an encoding.

    Deliberately narrow: a plain string that merely looks like Base64 (a queue name, a model id)
    must not trip this. Only a value that unwraps to a JSON document is an encoded config blob.
    """
    if not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", value or ""):
        return False
    try:
        decoded = base64.b64decode(value, validate=True).decode("utf-8").lstrip()
    except Exception:
        return False
    return decoded.startswith("{") or decoded.startswith("[")


def check_pin_consistency(pairs):
    """A service chart and its companion migration-Job chart must NEVER run a different image
    digest or chart.version in the same environment. CI records them in one commit and the
    promotion writes them in one commit, so a mismatch means the machinery drifted (or somebody
    edited one pin by hand), not a legitimate choice.

    Reads release.yaml / image.yaml directly, never `helm template`, so a Job-only chart with no
    ConfigMap is checked too. An env where either app has no pin yet is skipped.
    """
    failures = []
    for app_a, app_b in pairs:
        for env in ["dev"] + ENVS:
            ver_a, ver_b = chart_version(app_a, env), chart_version(app_b, env)
            dig_a, dig_b = image_digest(app_a, env), image_digest(app_b, env)
            if ver_a and ver_b and ver_a != ver_b:
                failures.append(f"{app_a}/{env} chart.version '{ver_a}' != {app_b}/{env} "
                                f"'{ver_b}': these two are promoted together.")
            if dig_a and dig_b and dig_a != dig_b:
                failures.append(f"{app_a}/{env} image.digest != {app_b}/{env} image.digest: "
                                f"{app_b} must run the EXACT image {app_a} runs.")
    return failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--charts-dir")
    args = ap.parse_args()

    exc = load_exceptions()
    allow_empty = exc.get("allowEmpty") or {}
    allow_env_only = exc.get("allowEnvOnly") or {}
    allow_inherited = exc.get("allowInherited") or {}
    allow_default = exc.get("allowChartDefault") or {}
    structural = set(exc.get("structuralKeys") or [])
    skip = set(exc.get("skipApps") or [])
    pin_pairs = [tuple(p) for p in (exc.get("pinPairs") or [])]

    apps = sorted(os.path.basename(p) for p in glob.glob(os.path.join(REPO, "apps", "*")))
    if args.app:
        apps = [a for a in apps if a == args.app]

    failures, notes = [], []
    failures.extend(check_pin_consistency(pin_pairs))
    for app in apps:
        rendered, charts = {}, {}
        for env in ENVS:
            ver = chart_version(app, env)
            if not ver:
                continue
            chart = fetch_chart(app, ver, args.offline, args.charts_dir)
            if not chart:
                notes.append(f"{app}/{env}: chart {ver} unavailable (skipped)")
                continue
            charts[env] = chart

            # 0. keys the chart expects the env to own must not fall back to a chart default.
            #    Runs for skipApps too: those lack a ConfigMap, not a replica count.
            stated = env_values(app, env)
            for key in OWNED_KEYS:
                if key in structural or key in (allow_default.get(app) or []):
                    continue
                if chart_declares(chart, key) and key not in stated:
                    failures.append(
                        f"{app}/{env}: '{key}' is not set in apps/{app}/{env}/values.yaml, so it "
                        f"silently inherits the chart default. Set it, or whitelist it under "
                        f"allowChartDefault with a reason.")

            if app in skip:
                continue
            data, err = render_configmaps(app, env, chart)
            if data is None:
                failures.append(f"{app}/{env}: helm template failed: {' '.join(err)}")
                continue
            rendered[env] = data

        if not rendered or not any(rendered.values()):
            continue

        # 1. no empty values
        for env, data in rendered.items():
            for k, v in sorted(data.items()):
                if v == "" and k not in (allow_empty.get(app) or []):
                    failures.append(f"{app}/{env}: ConfigMap key '{k}' renders EMPTY. Set it in "
                                    f"apps/{app}/{env}/values.yaml or whitelist it with a reason.")

        # 2. key sets agree across envs
        present = [e for e in ENVS if e in rendered]
        if len(present) > 1:
            union = set().union(*(set(rendered[e]) for e in present))
            for k in sorted(union):
                missing = [e for e in present if k not in rendered[e]]
                if missing and k not in (allow_env_only.get(app) or []):
                    have = [e for e in present if k in rendered[e]]
                    failures.append(f"{app}: ConfigMap key '{k}' present in {'+'.join(have)} but "
                                    f"MISSING in {'+'.join(missing)}: env drift.")

        # 3. no ConfigMap value may be Base64-encoded JSON
        for env, data in rendered.items():
            bad = sorted(k for k, v in data.items() if v and decodes_to_json(v))
            if bad:
                failures.append(f"{app}/{env}: ConfigMap key(s) {bad} hold Base64-encoded JSON. "
                                f"Write plain JSON in values.yaml and keep b64enc out of the chart.")

        # 4. no ConfigMap key may be inherited from the chart default
        for env in present:
            probed = render_with_perturbed_config(app, env, charts[env])
            if probed is None:
                continue
            inherited = sorted(k for k, v in rendered[env].items()
                               if k in probed and probed[k] == v
                               and k not in (allow_inherited.get(app) or []))
            if inherited:
                failures.append(f"{app}/{env}: ConfigMap key(s) {inherited} come from the CHART "
                                f"DEFAULT; nothing in apps/{app}/{env}/values.yaml drives them. "
                                f"State them in this env's config block.")

    for n in notes:
        print(f"note: {n}")
    if failures:
        print(f"\nFAIL: {len(failures)} problem(s)\n")
        for f in failures:
            print(f"  FAIL: {f}")
        return 1
    print("\nOK: every rendered ConfigMap key is stated and consistent across environments.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
