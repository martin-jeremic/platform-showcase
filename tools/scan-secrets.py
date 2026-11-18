#!/usr/bin/env python3
"""scan-secrets.py: repository hygiene gate for a public sample.

Fails on anything that looks like a credential, and on any GUID that is not
obviously fake. Every identifier in this repository must be a placeholder:
a GUID is either built from one repeated hex digit per group
(11111111-1111-1111-1111-111111111111) or is a well-known public constant.

This complements gitleaks (run in CI with a pinned image). It exists so the check
also runs on a workstation without Docker, and so the "only fake IDs" rule is
enforced, which no generic secret scanner knows about.

Standard library only.  Usage: python tools/scan-secrets.py [path ...]
"""
from __future__ import annotations

import os
import re
import sys

SKIP_DIRS = {".git", ".terraform", "node_modules", "__pycache__"}
SKIP_FILES = {"scan-secrets.py"}
TEXT_EXT = {".md", ".yaml", ".yml", ".tf", ".tfvars", ".example", ".json", ".sh", ".ps1", ".py",
            ".tpl", ".txt", ".conf", ".cs", ".csproj", ".props", ".toml", ".hcl", ".js", ".ts",
            ".sql", ".river", ".alloy", ".tmpl", ".gotmpl", ".env", ".cfg", ".ini", ""}

# Public, well-known GUIDs that may appear verbatim.
ALLOWED_GUIDS = {
    "00000000-0000-0000-0000-000000000000",  # ACR access-token username
    "499b84ac-1321-427f-aa17-267ca6975798",  # Azure DevOps resource (token audience)
    "8c6f20a7-a545-4486-9777-f762fafe0d4d",  # Azure DevOps "Approval" check type
    "00000003-0000-0000-c000-000000000000",  # Microsoft Graph application
}

GUID = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")

SECRET_PATTERNS = [
    ("private key", re.compile(r"-----BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY-----")),
    ("storage account key", re.compile(r"AccountKey=[A-Za-z0-9+/]{40,}={0,2}")),
    ("SAS signature", re.compile(r"[?&]sig=[A-Za-z0-9%+/]{20,}")),
    ("Logic App / webhook URL with signature", re.compile(r"https://[^\s\"']*(logic\.azure\.com|webhook\.office\.com)[^\s\"']*sig=")),
    ("JWT", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("GitHub/ADO-style token", re.compile(r"\b(ghp|gho|github_pat)_[A-Za-z0-9_]{20,}")),
    ("npm auth token", re.compile(r"_authToken\s*=\s*(?!\$\{)[A-Za-z0-9+/=_-]{20,}")),
    ("npm basic password", re.compile(r"_password\s*=\s*(?!\$\{)[A-Za-z0-9+/=]{20,}")),
    ("long base64 credential", re.compile(r"(?i)(password|secret|token|apikey|api_key)\s*[:=]\s*[\"']?[A-Za-z0-9+/]{32,}={0,2}[\"']?\s*$")),
    # A literal, not a reference: references (var.x, random_password.y.result, resolve_secret(...),
    # ${VAR}, <placeholder>) contain '.', '(', '$', '<' or '{' and are not credentials.
    ("literal password", re.compile(r"(?i)\b(password|passwd|pwd)\s*[:=]\s*[\"']?(?!REPLACE|CHANGE|example|placeholder|dev-only)[^\s\"'#.($<{\[*]{8,}[\"']?\s*(#.*)?$")),
]


def fake_guid(g: str) -> bool:
    g = g.lower()
    return g in ALLOWED_GUIDS or all(len(set(part)) == 1 for part in g.split("-"))


def scan(paths: list[str]) -> int:
    hits = 0
    for root in paths:
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if name in SKIP_FILES or os.path.splitext(name)[1].lower() not in TEXT_EXT:
                    continue
                path = os.path.join(dirpath, name)
                try:
                    with open(path, encoding="utf-8") as f:
                        lines = f.read().splitlines()
                except (UnicodeDecodeError, OSError):
                    continue
                for n, line in enumerate(lines, 1):
                    if "scan-secrets: allow" in line:
                        continue
                    for g in GUID.findall(line):
                        if not fake_guid(g):
                            print(f"GUID    {path}:{n}: {g} is not an obviously fake identifier")
                            hits += 1
                    for label, rx in SECRET_PATTERNS:
                        if rx.search(line):
                            print(f"SECRET  {path}:{n}: looks like a {label}")
                            hits += 1
    print(f"scan-secrets: {hits} finding(s)")
    return 1 if hits else 0


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    sys.exit(scan(sys.argv[1:] or [os.path.dirname(here)]))
