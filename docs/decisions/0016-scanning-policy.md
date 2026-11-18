# 0016 · Secret scanning blocks; vulnerability scanning warns

**Decision.**
- **Secret scanning blocks the PR.**
  - gitleaks scans the working tree of every PR and fails it on any finding.
  - It is pinned to an exact version. A drifting `latest` reported different counts on different agents.
  - Exceptions go into a repository allowlist, each with a reason.
- **Vulnerability scanning warns but keeps the run green.**
  - Trivy scans every built image for vulnerabilities and secrets: HIGH and CRITICAL, fixed-only.
  - Results are published as JUnit, one failed test per finding. A finding also adds a run tag and a summary.
  - The run stays green on purpose:
    - the downstream dev deployment triggers only on a successful run;
    - a new CVE in a base image must not stop the delivery of an unrelated fix.
- **Running images are scanned in-cluster.**
  - The Trivy Operator scans the images that are actually running.
  - An alert fires only for a finding that is all of:
    - **new**: not present in the same image during the previous week;
    - **fixable**;
    - **critical**;
    - on a cluster that has been scanning for at least two days.
  - The backlog lives on a dashboard.

**Lessons.**
- **Count findings with awk, not `grep | wc -l`.** `grep` exits 1 on zero matches, so with `pipefail` every clean image failed.
- **Scans found credentials baked into images.** Every Dockerfile that needs a private feed now uses a BuildKit secret mount instead.
