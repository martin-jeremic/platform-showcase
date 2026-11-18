# Known gaps

This page lists what is still wrong, what is accepted, and what would come next. Each folder's README has its own detailed KNOWN-GAPS section. This page is the cross-cutting summary, ordered by risk.

The sample shows several shortcuts from the original repositories in their corrected form. Those corrections are not repeated here. This page is only about what remains.

## Security

| Gap | Where | Why it is still there | Next step |
|---|---|---|---|
| The kubelet identity can read Key Vault on some clusters (the whole vault, not one service's objects) | infrastructure, gitops/services (`aks-org-prod`) | It was the only CSI auth mode that worked before per-workload identities existed. Product A's application layer has already moved to workload identity. | Move the remaining platform components and company services to per-workload identities. Then remove the kubelet's vault role. |
| The on-prem hub's CSI driver and image pulls use a long-lived service-principal secret | gitops/platform `hub/setup`, gitops/services `dev` | The on-prem cluster has no managed identity | Federate one identity per ServiceAccount through the published OIDC issuer (the same mechanism Argo CD already uses for Git) |
| The product production cluster keeps local accounts | infrastructure `product-a/aks-prod` | The OpenTofu Helm provider bootstraps Argo CD with the admin kubeconfig | Bootstrap with an Entra-authenticated kubeconfig (kubelogin), then disable local accounts |
| PostgreSQL uses a public endpoint with firewall rules; password auth is still enabled next to Entra auth | infrastructure | Applications use password connection strings | Private endpoint in the reserved subnet; move applications to Entra tokens |
| Open Keycloak findings | infrastructure `*/keycloak` | Changing default roles affects every user and needs a coordinated rollout | Fix in this order: realm-management roles in default roles; brute-force protection on older realms; PKCE on public SPAs; `web_origins ["+"]`; service-account roles with no confirmed owner |
| Users can change their own Keycloak group membership while the default-roles finding is open | docs/runbooks/argo-access.md | Same finding as above | Same fix. Until then, the Argo CD RBAC boundary is organisational, not technical |
| Registry admin user enabled on one registry; vault network ACLs open; state account keeps shared keys | infrastructure `org/*` | Adopted by import exactly as they were, so the first plan is a no-op | A second change per resource, each with its own consumer check |
| Trivy and hadolint are warn-only | platform/ci-templates | Decision: a new base-image CVE must not block an unrelated fix ([ADR-0016](decisions/0016-scanning-policy.md)) | Block only on *new*, fixable CRITICAL findings introduced by the change itself |

## Delivery

| Gap | Where | Why | Next step |
|---|---|---|---|
| Stage and demo promotions ship the dev image recorded **at approval time** together with the chart from the `main` run. A develop build between the two changes the image part of a pending approval. | platform/ci-templates `build-or-promote-stage` | The original design kept develop and main independent | Record digest and chart version as one pair at build time, and pass the pair into the approval as fixed parameters |
| The downgrade guard protects the chart pin but not the image/chart pairing above | platform/ci-templates `gitops-promote-steps` | Same as above | Same as above |
| Product A production sync is manual; there is no self-heal in production | gitops/apps `overlays/prod` | Pre-launch decision: automation is enabled per application through `release.yaml` | Enable per application after launch |
| Nothing orders the migration Application before the API Application in GitOps environments | gitops/apps | Argo CD sync waves do not cross Applications | Migrations must be expand/contract; a migration lint enforces it. A cross-Application gate (an Argo CD sync hook that waits for the Job) would remove the reliance on discipline |
| A concurrent promotion of the same application fails instead of re-validating | platform/ci-templates | The retry loop rebases, but does not re-run the downgrade guard against the new tip | Re-run the guard inside the retry loop |
| Product B has no GitOps repository yet; it is deployed by pipeline to a dev namespace | app/product-b | Product still in early development | Create its gitops/apps folder with the Product A model |
| `az acr build` has no BuildKit secret mount; the private feed token goes in as `--secret-build-arg` | platform/ci-templates, services | Remote builds have no local Docker daemon | Pull private packages from a proxy feed that the build identity can read, so no token is needed at all |
| The licence allow-list gate is not wired in | platform/ci-templates `examples/licence-allowlist.json` | It failed on an internal package that declares `UNLICENSED` | Allow-list internal scopes explicitly and re-enable it |

## Platform

| Gap | Where | Why | Next step |
|---|---|---|---|
| Argo CD's repo-server fetches upstream subcharts at render time | platform/charts (wrapper charts) | Vendored `.tgz` files were dropped from this sample; `Chart.lock` pins the versions | Vendor the subcharts again, or mirror them into the private OCI registry, so no render needs internet egress |
| RabbitMQ, Elasticsearch and MongoDB are single-replica | platform/charts | They are not clustered; they have retained volumes instead | Clustered brokers on production first; snapshot repositories for Elasticsearch |
| Some secrets are still seeded by hand: DNS-01 token, Argo CD and Grafana OIDC client secrets, Grafana admin | gitops/platform `*/setup` | Each is needed before the components that could manage it exist | Have OpenTofu write them to Key Vault and mount them through CSI, like the alerting credentials |
| NetworkPolicy is off by default | platform/charts | The on-prem CNI did not enforce it | Default-deny per namespace on AKS first |
| Grafana organisations live only in Grafana's SQLite database | platform/charts `observability` | They are created through the API | Provision organisations as code; back up the PVC |
| Values files are not versioned with the chart tag | gitops/platform | Values are read from `main`, so `git revert` is the only rollback | Tag values together with the descriptor bump |
| The island auto-promotes new chart tags to production | gitops/platform `island` | One cluster, one operator; the trade-off was accepted ([ADR-0015](decisions/0015-platform-chart-versioning.md)) | Promote through a reviewed PR once a second operator exists |
| Metrics from standalone clusters never reach the hub | platform/charts | Internet-facing clusters keep their own stack ([ADR-0010](decisions/0010-observability-hub-and-standalone.md)) | Federate a small set of SLO metrics to the hub |
| Clusters stopped on a schedule fire `PlatformClusterUnreachable` every night | platform/charts `rules/spokes.yaml` | Accepted rather than muted, so a real outage during the window still alerts | Inhibit the alert during the schedule window, driven by the same schedule variable |

## Availability and operations

| Gap | Where | Why | Next step |
|---|---|---|---|
| The company production cluster is a single node; company services run one replica | gitops/services, infrastructure `org/aks-prod` | Cost. [ADR-0017](decisions/0017-cost-controls.md) records why the second node comes last | Replicas, then hard anti-affinity, then honest requests, then the second node |
| The on-prem hub is a single node on office hardware | gitops/platform `hub` | It is the non-production hub; production is an island ([ADR-0002](decisions/0002-two-argo-topologies.md)) | Move the hub to a small managed cluster, or at minimum add a host watchdog and an external dead-man's switch |
| There is no alert on backup job failure | infrastructure | The backup vault's built-in alerts are not wired to Alertmanager | Azure Monitor action group for Backup, routed to the same channel |
| No dead-man's switch outside the cluster | platform/charts `observability` | `Watchdog` is routed to `null` | Send `Watchdog` to an external heartbeat service that pages when it stops |
| The payments e-mail worker has no probe; a hang without an exception is not restarted | app/payments | Headless worker with no HTTP listener | A file-touch liveness probe written by the processing loop |
| Some workers cannot scale out (in-process job store, no row locks) | app/product-a, app/product-b | Designed single-replica, with `Recreate` | Move job state to the database with `FOR UPDATE SKIP LOCKED` |
| Company charts accept `autoscaling.*` but render no HPA | services | Single node; HPA would have nothing to schedule onto | Add the template together with the second node |
| Alert-rule unit tests need promtool or Docker | platform/charts, tools/validate-all.sh | Not available on every workstation | They run in CI with a pinned Prometheus image |
