# AKS minor upgrade procedure

This procedure applies to every cluster in this folder. Kubernetes versions are
**minor aliases** (`"1.37"`) in a variable with a validation that refuses patch pins.
The patch upgrade channel keeps the patch current inside the maintenance windows.
Minor upgrades are a deliberate, reviewed change.

## Why the stack could not upgrade at first

The org cluster had `ignore_changes = [kubernetes_version, orchestrator_version]`,
and the comment said AKS auto-patches. The live cluster showed the opposite:

| What the config assumed | What was true |
|---|---|
| AKS auto-patches | The upgrade channel was `none`. Nothing patched, and the cluster sat several patches behind. |
| A patch shows up as drift | AKS stores the alias as sent. The resolved patch is a separate read-only field. A patch change cannot produce a diff. |
| Bump the variable to upgrade | `ignore_changes` discarded the bump. The variable did nothing. |
| Node images move `orchestrator_version` | They do not. Ignoring it would have left pools behind on every upgrade. |

The product cluster had a related bug. The system pool had no `orchestrator_version`,
so a minor bump moved the control plane and the user pools but left the system pool
on its create-time patch pin. The patch channel never crosses a minor, so it stayed
behind. **Every pool now sets `orchestrator_version = var.kubernetes_version`.**

## Procedure (one minor per apply)

1. **Survey, read-only.** Collect:
   - `az aks get-upgrades` (a non-LTS cluster cannot skip a minor);
   - the node pools and the regional vCPU quota (the surge node needs room);
   - deprecated API calls (`apiserver_requested_deprecated_apis`);
   - CRD served/stored versions;
   - PDBs (a `minAvailable` equal to the replica count blocks every drain);
   - the volume types and kube-proxy mode in use;
   - the published Kubernetes support range of every add-on with admission
     webhooks (cert-manager is the usual one).
2. **Check the release notes** of the target minor against the survey: removed
   APIs and volume drivers, containerd, cgroup v1, and AKS add-on bumps.
3. **Pick the window.** A stopped cluster rejects the upgrade, and a power-schedule
   stop that fires mid-upgrade fails its job. Run it during the day, with margin
   before the stop time.
4. **Change the default** in `variables.tf`, not in a git-ignored tfvars. Then run
   `tofu plan -out=upgrade.tfplan`. The plan must show **one** in-place change on
   the cluster: `kubernetes_version` and the default pool's `orchestrator_version`.
   User pools follow as their own in-place changes. Anything else: stop.
5. **Apply.** On a single node every pod restarts once. Pods with disks also wait for
   a detach and reattach.
6. **Verify.**
   - The control plane and every pool report the new minor.
   - Every node is Ready.
   - The cert-manager webhooks answer (they use `failurePolicy: Fail`).
   - Issuers and certificates are Ready.
   - No pod is stuck Pending on a volume.
7. Repeat for the next minor if needed. Never two minors in one apply.

## Residual risk worth naming

An add-on can run one minor past its tested range. The webhook check in step 6 is
what makes that acceptable.
