# platform/charts

The platform layer of every cluster in the fleet, as Helm charts: ingress, TLS,
secrets, identity, messaging, data stores, observability and GitOps itself.

**What the real repositories were.** Two chart repositories, merged here:

- the organisation's platform charts (`org-platform`), consumed by the **hub** Argo
  CD that manages four clusters;
- the product's platform charts (`product-a-platform`), forked from the first for
  the **island** production cluster (`aks-product-a-prod`) and hardened there to a
  production floor.

One chart per component, the more mature variant of each, with the other lineage's
techniques folded in. Charts are read by Argo CD **from git at a per-chart tag**
(`traefik-1.2.0`) -- there is no chart registry and no publish step. Cluster values
are not here: they live in [`../../gitops/platform`](../../gitops/platform).

## Where the charts run

| Cluster | Kind | Role | Observability mode |
|---|---|---|---|
| `hub-dev` | on-prem MicroK8s | hub (Argo CD in `argocd-hub`) | central stack + `observability-ingest` |
| `aks-org-prod` | AKS | spoke | standalone |
| `product-a-stage` | on-prem MicroK8s | spoke | `cluster-monitoring-agent` -> hub over OTLP mTLS |
| `aks-product-a-demo` | AKS | spoke | standalone |
| `aks-product-a-prod` | AKS | island (own Argo CD in `argocd`) | standalone, Loki/Tempo on Azure Blob |

The end-to-end observability flow (spokes -> OTLP mTLS -> hub, standalone
clusters, alert paths, retention) and the takeover-in-place method for
hand-installed Helm releases are described in
[`../../gitops/platform/README.md`](../../gitops/platform/README.md).

## Layout

| Chart | Kind | What |
|---|---|---|
| [`secrets-store-csi`](secrets-store-csi) | wrapper | Secrets Store CSI driver + Azure provider, rotation on; owns the Retain StorageClass (wave 0) |
| [`cert-manager`](cert-manager) | wrapper | cert-manager + ClusterIssuers (ACME DNS-01). Cannot template the DNS token |
| [`traefik`](traefik) | wrapper | Traefik in Gateway API mode, Gateway API CRDs + safe-upgrades policy, redirect, TLS floor, middlewares |
| [`reloader`](reloader) | wrapper | Stakater Reloader, fleet-wide, HA |
| [`rbac`](rbac) | own | Entra group object IDs -> RoleBindings; refuses to render without real GUIDs |
| [`oidc-issuer`](oidc-issuer) | own | publishes an on-prem cluster's SA token issuer (workload identity without AKS) |
| [`argocd`](argocd) | wrapper | Argo CD, self-managed after the OpenTofu bootstrap; route + OIDC |
| [`argocd-cluster-registry`](argocd-cluster-registry) | own | spoke registrations as ExternalSecrets (tokens in Key Vault) |
| [`keycloak`](keycloak) | own | Keycloak 26, clustered (DNS_PING), Postgres, Key Vault secrets |
| [`rabbitmq`](rabbitmq) | own | RabbitMQ 4.2, Retain storage, feature flags, per-object metrics |
| [`elasticsearch`](elasticsearch) | own | single-node Elasticsearch, auth on, no route, no hostPath |
| [`mongo`](mongo) | own | standalone MongoDB + guarded mongodump-to-Blob CronJob |
| [`azurite`](azurite) | own | Azure Storage emulator for clusters without a Storage account |
| [`minio`](minio) | wrapper | minimal MinIO + routes (placeholder) |
| [`postgres-exporter`](postgres-exporter) | own | observes the external Azure PostgreSQL server |
| [`observability`](observability) | wrapper | kube-prometheus-stack + Loki + Alloy + Tempo; hub or standalone |
| [`observability-ingest`](observability-ingest) | wrapper | hub OTLP gateway: mTLS, cert-manager PKI, per-spoke tenancy |
| [`observability-log-rules`](observability-log-rules) | own | LogQL alert rules for one Loki tenant |
| [`cluster-monitoring-agent`](cluster-monitoring-agent) | wrapper | spoke agent: Alloy + node-exporter + kube-state-metrics, one OTLP mTLS egress |
| [`grafana-sso-gateway`](grafana-sso-gateway) | own | Grafana route + Keycloak OIDC config (no credential) |
| [`trivy`](trivy) | wrapper | Trivy Operator, ClientServer mode, per-finding metrics |
| [`vpa`](vpa) | wrapper | VPA in measurement-only form |
| [`headlamp`](headlamp) | own | Kubernetes UI acting with the user's own token |
| [`cluster-test`](cluster-test) | own | smoke-test nginx page rendered from the Downward API |
| [`tools/`](tools) | | `check-platform.sh`, `render-gates.py`, `chart-version.sh`, `check-log-rules.sh`, `check-dashboard-threshold.py`, `validate-dashboards.py`, `compare-log-contract.py` |
| [`azure-pipelines.yml`](azure-pipelines.yml) | | PR auto-bump, gates, tag + promote |

Every chart has `ci/*.yaml` test values in the shape of a real cluster's gitops
values. Wrapper charts declare their upstream charts in `Chart.yaml` at exact
versions; `charts/` is gitignored and `helm dependency build` fetches them.

## Conventions

- **The production floor**, on every workload unless documented otherwise: `pool`
  node placement **with** the matching `workload=<pool>:NoSchedule` toleration;
  two replicas with a **hard** (`DoNotSchedule`) hostname spread and a PDB for
  stateless services; requests **and** limits; priority tiers --
  `system-node-critical` for per-node DaemonSets, `system-cluster-critical` for
  platform services. Documented exceptions: single-replica StatefulSets with no
  clustering (rabbitmq, elasticsearch, mongo) and evict-first diagnostics
  (cluster-test, postgres-exporter, azurite, headlamp). `render-gates.py` enforces
  the floor per rendered workload.
- **No credential in any values file, and no template that can render one.** Key
  Vault over the Secrets Store CSI driver, with **workload identity as the default
  auth** in every consumer (`useVMManagedIdentity: "false"` + a per-workload
  `clientID`); `vmManagedIdentity` and `servicePrincipal` stay as explicit options.
  The few secrets no pod mounts (DNS token, OIDC client secrets, Grafana break-glass
  admin) are seeded once from the gitops `setup/` folders.
- **Refuse instead of default.** A missing hostname, cluster identity, storage
  class or GUID fails the render (an Argo `ComparisonError`, nothing applied)
  instead of rendering something plausible and wrong.
- **Templates do not fall through to the cluster `default` StorageClass**
  (reclaimPolicy Delete). Stateful charts name `platform-retain`.

## Key techniques

**Edge (traefik)**
- [Gateway API CRDs owned by the chart](traefik/crds/gateway-api-standard-install.yaml) plus the upstream
  [safe-upgrades ValidatingAdmissionPolicy](traefik/templates/gateway-api-safe-upgrades.yaml) -- a one-way ratchet.
- [HTTP->HTTPS redirect bound only to the `web` listener](traefik/templates/redirect-httproute.yaml) (`sectionName`), and
  application routes only on `websecure` ([httproutes.yaml](traefik/templates/httproutes.yaml); gated in `render-gates.py`).
- [TLS floor as a `default` TLSOption whose namespace is required](traefik/templates/tlsoption.yaml) and equal to `defaultTLSResourcesNamespace`.
- [Middlewares rendered into every consuming namespace](traefik/templates/middlewares.yaml) (ExtensionRef is namespace-local):
  HSTS attached at the `websecure` entrypoint, the auth rate limit on the Keycloak and Argo CD routes.

**Storage and secrets**
- [Retain StorageClass owned by wave 0](secrets-store-csi/templates/retain-storageclass.yaml).
- Workload identity in three pieces (SA annotation, pod label, federated credential) -- e.g.
  [rabbitmq/serviceaccount.yaml](rabbitmq/templates/serviceaccount.yaml); `nodePublishSecretRef` only in `servicePrincipal` mode.
- [cert-manager `startupapicheck` off under Argo](cert-manager/values.yaml) -- a Helm hook becomes a PostSync job that reports red for unrelated reasons.

**Stateful services**
- RabbitMQ: [`.erlang.cookie` chmod init container, feature-flags postStart, per-object metrics through a `subPath` conf.d drop-in, Reloader on the workload](rabbitmq/templates/statefulset.yaml); [pinned job label](rabbitmq/templates/servicemonitor.yaml); [no `guest`, no Secret from values](rabbitmq/templates/_helpers.tpl).
- Elasticsearch: [exec probes reading the password from the env](elasticsearch/templates/statefulset.yaml), auth on by guard, Reloader on the StatefulSet.
- Keycloak: [headless Service with `publishNotReadyAddresses`](keycloak/templates/service-headless.yaml);
  [topology selector derived from `selectorLabels` + `minDomains`](keycloak/templates/deployment.yaml);
  [`KC_HOSTNAME` built as a URL, and the configmap chomp-trap comment](keycloak/templates/configmap.yaml).
- Argo CD: [the topology selector gotcha](argocd/values.yaml) (`<nameOverride>-<component>`, not the fullname).
- Mongo: [backup CronJob](mongo/templates/cronjob.yaml) -- dump in an init container, upload in the main one, empty-archive check,
  `--overwrite false`, password through a 0600 file instead of argv, refuses to render half-configured.

**Observability**
- [Alertmanager config rendered by the chart](observability/templates/alertmanager-config.yaml): per-audience route trees,
  receiver shorthands, **`set` not `merge`** (sprig's merge drops `false`), and
  [derived template defines](observability/templates/_helpers.tpl) (Grafana root, Loki uid) instead of retyped literals.
- [Graph `/sendMail` webhook receiver with OAuth2 client credentials, and a Teams Logic App webhook, both from CSI-mounted files](observability/templates/alertmanager-secretproviderclass.yaml);
  [mail subject starts with a status word](observability/alertmanager/notifications.tmpl) (Alertmanager YAML-re-parses payload strings); Alertmanager pinned >= 0.34.
- [Default scrape class](observability/values.yaml) stamping `cluster` from `externalLabels` -- no per-monitor relabelings, so the kubelet
  `metrics_path` default survives (and the [agent restates `metrics_path`](cluster-monitoring-agent/templates/_helpers.tpl) for the mixins).
- [`assertions.yaml`](observability/templates/assertions.yaml): one cluster identity, ruler dir == sidecar folder, ruler -> this Alertmanager,
  Loki index/chunk store agree, explicit storage classes, explicit dashboard `searchNamespace`, priority floor.
- Rules: [Argo `dest_cluster` recording rule](observability/rules/argocd.yaml) so app alerts route by destination;
  ["was there, now gone"](observability/rules/spokes.yaml) (`max_over_time(x[7d]) unless x`) instead of `absent()`;
  [new-CVE offset rule with a 2-day warm-up](observability/rules/trivy.yaml); [scale events as `notice`](observability/rules/scaling.yaml)
  (escapes the InfoInhibitor); [dormant-by-design postgres rules](observability/rules/postgres.yaml). Unit tests in [`rules/tests/`](observability/rules/tests).
- Logs: [Alloy log-contract stage](observability/templates/_helpers.tpl) mirrored by [observability-ingest](observability-ingest/templates/_helpers.tpl)
  (envelope unwrap, `stage.tenant`, one Tempo filter+exporter per spoke), compared by `tools/compare-log-contract.py`;
  [Loki rules via the sidecar with a file-count guard](observability-log-rules/templates/configmap.yaml).
- Grafana's [two Secret mechanisms](observability/values.yaml): `envFromSecrets` for env-named config keys, `envValueFrom` for `client-secret`.
- [OTLP mTLS gateway with its own cert-manager PKI](observability-ingest/templates/pki.yaml); [agent with ONE mTLS export, certs from Key Vault](cluster-monitoring-agent/templates/secretproviderclass.yaml).

**Delivery**
- [`chart-version.sh`](tools/chart-version.sh): `tag == <chart>-<version>`, PR auto-bump, tripwire, tags cut on main, promote only to tags on origin, push retried.
- [`render-gates.py`](tools/render-gates.py) + [`check-platform.sh`](tools/check-platform.sh): no PV, no route on `/`, no route on every listener,
  no literal password, no `REPLACE_WITH_`, no `:latest`, no `example-internal`, floor per workload; 20 refusal tests.

## Mongo: rotation and restore (referenced from the chart)

- **Why standalone.** One mongod, no replica set: the consumers need no failover,
  and a replica set on one node buys nothing but complexity. The headless Service
  already gives the pod the stable DNS name a later replica set would use.
- **Rotating the admin password.** `MONGO_INITDB_ROOT_PASSWORD` is honoured only on
  an EMPTY data directory. Change it in mongod first
  (`db.changeUserPassword()`), then in Key Vault; never the other way round. That
  is why Reloader is OFF for this chart: a restart after a vault rotation makes it
  look like the rotation worked while the database password never changed.
- **Restoring into the volume.** `fsGroupChangePolicy: OnRootMismatch` assumes a
  correct root dir implies a correct tree. A dump restored into the PVC as root
  breaks that assumption: chown the tree to 999 before starting mongod.

## How to validate

```sh
cd platform/charts
tools/check-platform.sh          # deps, lint + render every ci/*.yaml, gates, refusals,
                                 # dashboards, threshold, log-contract comparison
tools/check-log-rules.sh         # lokitool at the rendered Loki version + rule fields
promtool test rules observability/rules/tests/*.yaml   # CI runs it from the rendered Prometheus image
```

## KNOWN-GAPS

- **Argo CD fetches subcharts at render time.** `charts/` is no longer committed, so
  the repo-server runs `helm dependency build` and needs egress to the upstream Helm
  repositories (pinned by `Chart.lock`). The original repos vendored the `.tgz`
  files to avoid exactly that; a private OCI mirror would restore offline renders.
- **Single-replica stateful services.** RabbitMQ, Elasticsearch and MongoDB have no
  clustering; real HA is a different chart (quorum queues, a multi-node ES, a
  replica set).
- **Hand-seeded secrets remain.** The DNS-01 token, the Argo CD and Grafana OIDC
  client secrets and Grafana's break-glass admin have no pod that mounts a CSI
  volume. External Secrets Operator would close it on the island too (the hub
  already runs it for cluster registrations).
- **NetworkPolicy is off** (elasticsearch ships one, disabled) until each cluster's
  CNI policy enforcement is confirmed; an unenforced policy reads as protection
  that is not there.
- **Prometheus and Loki are not published**: Grafana is the only authenticated way
  in. Enabling their routes needs auth at the edge first.
- **Grafana Orgs live only in its SQLite DB** (Retain PVC, no backup tooling).
- **`postgres-exporter` is pending** (no descriptor); its rules are dormant by
  design until it lands.
- **Alert rule unit tests were not executed here**: no promtool or Docker in this
  environment. CI runs them from the rendered Prometheus image.
- **Tags are immutable by convention** plus a tag-protection policy, not by a
  registry.
