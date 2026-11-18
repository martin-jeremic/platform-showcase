# gitops/platform

How the platform charts ([`../../platform/charts`](../../platform/charts)) reach the
clusters. Two delivery models existed side by side, and both are here:

| Folder | Real repository | Model |
|---|---|---|
| [`hub/`](hub) | `org-platform-gitops` | **Hub and spoke**: one Argo CD on the on-prem hub manages itself and three spokes |
| [`island/aks-product-a-prod/`](island/aks-product-a-prod) | `product-a-platform-gitops` | **Island**: the product's production cluster runs its own in-cluster Argo CD and depends on nothing else |

Both share the mechanics: a git-files generator per cluster, **presence of
`platform/<cluster>/<component>.yaml` = the component runs there**, a
`catalog.yaml` of invariants, `component.sh`, sync waves,
`goTemplateOptions: [missingkey=error]`, multi-source Applications (chart at a
**per-chart git tag**, values from the gitops repo), `ServerSideApply`,
`ServerSideDiff` as an annotation, and `templatePatch` for per-descriptor flags.

## The fleet

| Cluster | Kind | Role | Argo CD | Observability mode |
|---|---|---|---|---|
| `hub-dev` | on-prem MicroK8s, single node | hub; dev environment of the company services | hub Argo CD in `argocd-hub` (self-managed, manual sync) | **central** stack: its own data plus every agent spoke's |
| `aks-org-prod` | AKS, single node | company services production | spoke of the hub | **standalone** stack, own Alertmanager |
| `product-a-stage` | on-prem MicroK8s, single node | product stage | spoke of the hub | **agent** (`cluster-monitoring-agent`) shipping to the hub |
| `aks-product-a-demo` | AKS, two infra nodes | product demo | spoke of the hub | **standalone** stack, own Alertmanager |
| `aks-product-a-prod` | AKS, production node pools | product production | **island**: own Argo CD in `argocd`, self-managed | **standalone** stack, Loki/Tempo on Azure Blob |

Current hub matrix (`sh hub/platform/component.sh matrix` regenerates it):

<!-- MATRIX:START -->
| component | hub-dev | aks-org-prod | product-a-stage | aks-product-a-demo |
|---|:--:|:--:|:--:|:--:|
| argocd | yes | -- | -- | -- |
| argocd-cluster-registry | yes | -- | -- | -- |
| observability | yes | yes | -- | yes |
| observability-ingest | yes | -- | -- | -- |
| observability-log-rules | yes | -- | -- | yes |
| grafana-sso-gateway | yes | yes | -- | yes |
| cert-manager | yes | yes | -- | yes |
| traefik | yes | yes | yes | yes |
| reloader | yes | yes | yes | yes |
| secrets-store-csi | yes | yes | yes | yes |
| oidc-issuer | yes | -- | -- | -- |
| vpa | yes | -- | -- | -- |
| trivy | yes | yes | -- | -- |
| cluster-monitoring-agent | -- | -- | yes | -- |
| rbac | -- | yes | -- | -- |
| rabbitmq | -- | -- | yes | -- |
| elasticsearch | -- | -- | -- | yes |
| mongo | -- | yes | -- | -- |
| azurite | -- | -- | yes | -- |
| cluster-test | -- | -- | -- | -- |
| headlamp | -- | -- | -- | -- |
| minio | -- | -- | -- | -- |
<!-- MATRIX:END -->

The island runs `secrets-store-csi, cert-manager, traefik, reloader, rbac,
rabbitmq, elasticsearch, keycloak, argocd, cluster-test, grafana-sso-gateway,
observability` and one `observability-log-rules` release
(`sh island/aks-product-a-prod/platform/component.sh list`).

## Layout

```
hub/
  argocd/root-application.yaml        applied once by hand; renders argocd/ via kustomize
  argocd/kustomization.yaml           ONLY projects + appsets (setup/ excluded)
  argocd/projects/platform-<c>.yaml   one AppProject per cluster, developer role per Keycloak group
  argocd/appsets/platform-<c>.yaml    one ApplicationSet per cluster
  argocd/setup/                       one-time, unmanaged: repo-creds (workload identity), OCI helm repo,
                                      cluster secret template, secrets-store-creds template
  platform/catalog.yaml               component invariants (+ advisory scope)
  platform/component.sh               add | remove | list | bump | matrix | validate
  platform/render-descriptors.sh      every descriptor rendered at its tag with its values (CI)
  platform/<cluster>/<comp>.yaml      DESCRIPTORS -- presence = deployed
  platform/values/<cluster>/<comp>.yaml  VALUES -- what each chart is given
  azure-pipelines.yml                 validate, render all, nothing-from-setup/
island/aks-product-a-prod/
  argocd/{root-application,kustomization}.yaml, projects/, appsets/, applications/grafana-dashboards.yaml, setup/
  platform/{catalog.yaml,component.sh,render-descriptors.sh,aks-product-a-prod/,values/aks-product-a-prod/}
  dashboards/aks-product-a-prod/      kustomize, one configMapGenerator per Grafana folder
  scripts/seed-secrets.ps1            CSPRNG passwords into Key Vault, `-o none`
  RELEASING.md                        tag = available, descriptor bump = live
  azure-pipelines.yml
```

Descriptors and values are in **disjoint trees** (`platform/values/<cluster>/`,
never `platform/<cluster>/values/`): the generator globs `platform/<cluster>/*.yaml`,
and a values file under that prefix would be parsed as a descriptor, hit
`missingkey=error`, and fail generation for every component of the cluster.

## Key techniques

- **Charts pinned by tag, values always multi-source** ([hub appset](hub/argocd/appsets/platform-aks-org-prod.yaml)).
  The hub originally tracked `targetRevision: main` and kept values beside the
  charts as `values-<cluster>.yaml`, with this repo's values as an opt-in
  `gitopsValues: true` fourth file. The **values migration** moved every values
  file here, add-before-delete, each step gated on an empty render diff, then
  collapsed the opt-in into the base template, pinned the charts by tag and turned
  `ignoreMissingValueFiles` off: a missing values file now fails the render instead
  of deploying chart defaults while reporting Synced.
- **One AppProject per cluster, deny by default** ([projects/](hub/argocd/projects)): only the cluster's destination, and one
  `developer` role (get, sync, actions, logs -- no edit, delete, create) bound to a
  Keycloak group. One malformed policy line disables every policy of the project,
  silently.
- **The AKS admissions-enforcer carve-out**: `jqPathExpressions` on webhook
  `namespaceSelector` entries selected by key name, `ServerSideDiff` as a
  compare-option annotation, `RespectIgnoreDifferences=true` -- all three, or Argo
  fights Azure on every sync. Plus the Reloader `last-reloaded-from` annotation on
  Deployments, StatefulSets, DaemonSets and CronJobs.
- **`templatePatch` with `hasKey`**: `selfManaged: true` (hub `argocd`: no automated
  sync) and `prune: false` (island `argocd`). A string block, so the conditional is
  legal and the file stays valid YAML for the root's kustomize render; the patch
  names only `syncPolicy`, because naming `sources` would replace the list.
- **Hub guards**: no resources finalizer and `preserveResourcesOnDeletion: true` on
  the hub's own appset -- removing a descriptor never cascades into ingress or Argo
  itself.
- **`component.sh`** ([hub](hub/platform/component.sh)): its catalog parser reads fields at the component's own indent and stops
  at the first hit, because a folded `notes: >-` line that happened to start with
  `prune: false` once produced a two-line value, and the argocd descriptor came out
  without its guard. `validate` checks every field the template reads, a
  tag-shaped `chartRevision`, the values file, and catalog drift (a WARN:
  adopt-in-place descriptors override release names legitimately).
- **Nothing from `setup/`**: credentials Argo needs to read the repo are never
  Argo-managed; CI renders the root and fails if a Secret or a setup file name
  appears ([hub CI](hub/azure-pipelines.yml)).
- **Island specifics**: an [explicit `clusterResourceWhitelist`](island/aks-product-a-prod/argocd/projects/product-a-platform.yaml);
  the [self-management handoff](island/aks-product-a-prod/argocd/setup/README.md) from the
  OpenTofu `helm_release` (same release name `argocd`, same `fullnameOverride`, same
  chart version, tofu release frozen afterwards); a
  [dashboards Application](island/aks-product-a-prod/argocd/applications/grafana-dashboards.yaml) with
  [one `configMapGenerator` per folder](island/aks-product-a-prod/dashboards/aks-product-a-prod/kustomization.yaml);
  [`seed-secrets.ps1`](island/aks-product-a-prod/scripts/seed-secrets.ps1) (CSPRNG, `-o none`, rotation caveats);
  [`RELEASING.md`](island/aks-product-a-prod/RELEASING.md) (CI auto-promotes the island; the hub stays a reviewed bump).

## Observability end to end

```
 product-a-stage (agent spoke)                     hub-dev (central)
 ┌────────────────────────────────┐                ┌──────────────────────────────────────────────┐
 │ Alloy DaemonSet                │  OTLP gRPC     │ observability-ingest (Alloy, 2 replicas)     │
 │  kubelet/cAdvisor (metrics_path│  mTLS, client  │  verifies the client cert (CN = cluster)     │
 │  restated), node-exporter,     ├──cert = the ──▶│  metrics -> Prometheus remote_write          │
 │  kube-state-metrics, rabbitmq, │  cluster's     │  logs    -> unwrap OTLP envelope, parse the  │
 │  trivy; logs from the API      │  identity      │             log contract, stage.tenant =     │
 │  (this node only); OTLP traces │                │             cluster -> Loki                  │
 │  stamps cluster=product-a-stage│                │  traces  -> one filter + exporter per spoke, │
 │  certs: Key Vault via CSI      │                │             X-Scope-OrgID = cluster -> Tempo │
 └────────────────────────────────┘                │ Prometheus/Loki/Tempo/Grafana/Alertmanager   │
                                                    │  + the hub's own Alloy (log files on node)   │
                                                    └──────────────────────────────────────────────┘
 aks-org-prod, aks-product-a-demo, aks-product-a-prod: the same chart in STANDALONE mode --
 their own Prometheus, Loki (filesystem or Azure Blob), Alertmanager; nothing crosses clusters.
```

- **Identity**: one value per cluster (`externalLabels.cluster`); the default scrape
  class stamps it on every local target, spoke agents stamp it before export, and
  `assertions.yaml` refuses a log identity that differs. On the hub, `cluster` is the
  only thing separating its own series from the spokes', so every rule aggregates
  `by (cluster, ...)`.
- **Tenancy**: Loki and Tempo run multi-tenant; tenant = cluster. The hub's Grafana
  Main Org queries all tenants with a pipe-joined `X-Scope-OrgID`; per-scope Orgs get
  single-tenant datasources.
- **Alert paths**: Prometheus rules (per-file gates) and Loki ruler rules
  (`observability-log-rules`, one release per tenant) -> the cluster's own
  Alertmanager -> **Teams** (Logic App webhook, URL from a Key Vault file) for
  critical and security, **mail through Microsoft Graph `/sendMail`** (OAuth2 client
  credentials from a Key Vault file; Exchange-scoped sender, no tenant-wide
  Mail.Send) for everything else, `notice` as a daily digest. The hub routes the
  agent spoke's alerts to that spoke's audience (`notifications.audiences`) through
  a copy of the same route tree. The hub-side signal for the standalone clusters is
  Argo's own connection status (`PlatformClusterUnreachable`); a silent agent spoke
  is `PlatformClusterSilent`.
- **Retention**: metrics 10 days, logs 90 days (Loki compactor), traces 24 hours,
  Alertmanager silences/notifications 120 hours.

## Taking over hand-installed Helm releases in place

Most clusters were running push-installed Helm releases before Argo existed for
them. They were **adopted, not reinstalled** -- no outage, no data move:

1. **Match the identity.** The descriptor names the LIVE release name and
   namespace (overriding the catalog where needed; `validate` reports that as a
   WARN, by design), and the cluster's values reproduce what is running. A
   different release name makes Argo install a SECOND copy next to the first --
   for anything with a RWO volume that is two writers on one disk.
2. **Diff before landing.** Render the descriptor exactly as Argo would, then
   `kubectl diff --server-side --field-manager=argocd-controller -f render.yaml`
   (a server-side dry run as Argo's field manager). The only expected lines are
   Argo's tracking annotation and deliberate changes; anything else is fixed in the
   values first. Batches of one to three descriptors at a time.
3. **Conflicting list entries.** `ServerSideApply` keeps list entries another field
   manager owns. Where the new render re-types or renames a Helm-owned entry, the
   apply merges both and the server rejects it -- e.g. a DaemonSet volume that
   changes from `secret` to `csi` under the same name ("may not specify more than 1
   volume type"), or a CSI driver whose host mount path changes and leaves the old
   mount beside the new one forever. One-time fix, immediately before that
   descriptor lands: `kubectl delete daemonset <name> --cascade=orphan`. The pod
   keeps running; Argo creates the DaemonSet as its only field manager, adopts the
   pod and rolls it. (Rejected: renaming the volume -- it leaves a dead Helm-owned
   entry in the pod spec; clearing `managedFields` -- the stale entries stay, just
   unowned.)
4. **Retire the Helm records.** Once each Application is Synced and Healthy, delete
   that release's `sh.helm.release.v1.<release>.v*` Secrets, batch by batch, so a
   stray `helm upgrade` or `helm uninstall` cannot act on Argo-owned objects.
   Never `helm uninstall` an adopted release: it deletes the objects Argo now owns.
5. Only then flip the cluster's appset to automated prune + selfHeal (the hub keeps
   its no-cascade guards regardless).

## How to validate

```sh
sh  hub/platform/component.sh validate
bash hub/platform/render-descriptors.sh ../../platform/charts --worktree    # CI: at the pinned tags
kubectl kustomize hub/argocd
sh  island/aks-product-a-prod/platform/component.sh validate
bash island/aks-product-a-prod/platform/render-descriptors.sh ../../platform/charts --worktree
kubectl kustomize island/aks-product-a-prod/argocd
kubectl kustomize island/aks-product-a-prod/dashboards/aks-product-a-prod
```

## KNOWN-GAPS

- **Values are not pinned.** Charts move by tag; values move with `main` on the next
  sync. Deliberate (operating the platform is mostly values changes), but `git
  revert` is the only values rollback.
- **The island auto-promotes chart tags** to production on merge; the review gate
  is the charts PR. Acceptable for one cluster and one operator, and the first
  thing to reinstate if either grows.
- **Hand-seeded bootstrap secrets** (setup/ folders) have no rotation automation.
- **Single-node clusters** (hub-dev, aks-org-prod, product-a-stage) run one replica
  of everything; the production floor's spread and PDBs only bite on the island and
  the demo cluster. A NotReady node is therefore treated as critical everywhere.
- **The standalone clusters' metrics never reach the hub**: the hub sees them only
  through Argo's connection status. A cross-cluster view needs either the agent
  model or federation.
- **Nightly scheduled shutdowns** of aks-org-prod and aks-product-a-demo fire
  `PlatformClusterUnreachable` every evening; accepted rather than muted (an
  Alertmanager `mute_time_interval` is the fix if it must go).
- **The hub is a single on-prem node** whose control plane depends on one disk; its
  failure chain has dedicated alerts (`rules/controlplane.yaml`) but no redundancy.
