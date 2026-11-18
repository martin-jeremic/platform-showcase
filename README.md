# Platform engineering sample: Azure · Kubernetes · GitOps

This is an anonymised, trimmed rendering of a platform that one engineer designed, built and ran. It covered:
- two SaaS products;
- a set of internal company services;
- six Kubernetes clusters, on-premises (MicroK8s) and in Azure (AKS).

The code is organised in four areas: `app`, `platform`, `infra`, `gitops`. Each folder inside an area stands for one or more real repositories. The structure, techniques, comments and trade-offs are the real ones. The names, hosts, IDs and business logic are not.

> **Scope:**
> - Infrastructure as code (OpenTofu).
> - Platform Helm charts.
> - Hub-and-spoke GitOps with Argo CD.
> - Build-once / promote-by-digest delivery on Azure DevOps.
> - Identity: Entra ID, workload identity federation, Keycloak.
> - Secrets: Key Vault through the CSI driver.
> - Observability: Prometheus, Loki, Tempo, Grafana and Alloy, with OTLP mTLS from spokes and alerts as tested code.
> - The service-side contract that application teams ship against.

It is a sample for reading. It is not a copy you can deploy as-is.

---

## Start here

| If you have… | Read |
|---|---|
| 5 minutes | [Architecture](docs/architecture.md), then [Delivery flow](docs/delivery-flow.md) |
| 20 minutes | The [decision records](docs/decisions/README.md): what was chosen, why, what it cost, what broke |
| An afternoon | Any folder below. Every folder has its own README, with the techniques worth looking at, how to validate it, and its known gaps |

## Repository map

```
app/          where the code of the services lives      (service repositories)
platform/     what every service runs on                (platform charts, shared pipeline templates)
infra/        what the clusters run on                  (OpenTofu)
gitops/       what runs where                           (Argo CD repositories)
docs/         how it is operated                        (architecture, decisions, runbooks, known gaps)
tools/        repository-wide checks
```

| Area | Folder | Real-world role | Highlights |
|---|---|---|---|
| **app** | [app](app) | Service repositories: two products and the company services | .NET (chiseled), Python, Angular, React and NestJS services that follow the platform contract: health split, JSON logs, non-root, read-only root filesystem, digest-only images, explicit config keys, migrations as Jobs |
| **platform** | [platform/charts](platform/charts) | Platform Helm charts | 24 charts with a production floor (HA, spread, PDBs, two priority tiers). Identity, data and edge services: Keycloak, RabbitMQ, Elasticsearch, MongoDB, Traefik with Gateway API and a TLS floor. An observability hub with an OTLP mTLS ingest gateway. Alertmanager to Teams and Graph mail, with credentials from Key Vault. Render-time assertions and promtool-tested rules |
| | [platform/ci-templates](platform/ci-templates) | Shared Azure DevOps templates | Build once, record the digest, then an approval-gated promotion with retry and a downgrade guard. Also semantic versioning, PR gates, migration Jobs and idempotent ADO bootstrap scripts |
| **infra** | [infra](infra) | Two OpenTofu repositories (product and organisation) | A hardened state backend. Production AKS with an HA seam that separates in-place settings from create-time ones. PostgreSQL with tiered long-term backup and per-container workload identities. Argo CD bootstrapped by OpenTofu, then self-adopted. Alerting credentials with zero Graph permissions. Hand-built resources adopted by import, not rebuilt. Keycloak realms generated from live by an exporter |
| **gitops** | [gitops/platform](gitops/platform) | Platform GitOps, in two delivery models | Hub-and-spoke: one ApplicationSet per cluster, where a descriptor's presence means deployed. Island: a self-managed in-cluster Argo CD with charts pinned by per-chart tags |
| | [gitops/apps](gitops/apps) | Application GitOps for a product | Promotion state as plain data (`image.yaml`, `release.yaml`). Two render targets for two Argo instances. A ConfigMap *perturbation* check that proves every key is stated per environment |
| | [gitops/services](gitops/services) | Application GitOps for internal services | One ApplicationSet, with the project derived from the namespace (fails closed). Shared charts. Takeover of legacy Helm releases (field-manager surgery) |
| | [docs](docs) | Operating the platform | Architecture, delivery flow, 17 decision records, runbooks, known gaps |

**Where Keycloak and Backstage live.** Keycloak is split by layer:
- the Keycloak server is a platform chart: [platform/charts/keycloak](platform/charts/keycloak);
- realms, clients and groups are OpenTofu: [infra/product-a/keycloak](infra/product-a/keycloak) and [infra/org/keycloak](infra/org/keycloak).

Backstage is represented only by what the other layers carry:
- every service's `catalog-info.yaml`;
- its federated identity in [infra/org/identities/backstage](infra/org/identities/backstage).

The Backstage application itself is not part of this sample.

## How a change reaches production

1. **Develop branch: build once, record the digest.**
   - CI builds the image once, remotely in the registry.
   - It scans the image and resolves the image's `sha256` digest.
   - It records that digest as the dev candidate in the GitOps repository.
2. **Main branch: publish the chart, queue the promotions.**
   - A merge to `main` publishes the versioned chart.
   - It queues promotion stages that wait for an approval in an Azure DevOps Environment.
3. **Approval: write two plain-data files.**
   - Approving a promotion commits two files to the target environment's folder: the digest and the exact chart version.
   - No Argo CD manifest is edited. The approval *is* the deployment.
4. **Argo CD reconciles.** An ApplicationSet watches those files, and Argo CD syncs the cluster to exactly that pair.
5. **Production copies stage.** Production can only receive the image and chart pair that stage is running.

Rollback is `git revert`. Details and the second (company) variant are in [docs/delivery-flow.md](docs/delivery-flow.md).

## Principles visible in the code

- **The repository layout is the deployment model.**
  - A file's presence deploys something; removing the file removes it.
  - No hand-maintained list can drift.
- **Fail closed, fail early.**
  - Charts `fail` the render on a missing digest, an empty group ID, an unfilled placeholder, or an impossible combination.
  - Promotions refuse to write a pin that could not render.
  - A missing values file is an error, never a silent fallback.
- **No stored credentials where an identity can do the job.** That means:
  - workload identity per pod;
  - OIDC federation from an on-prem cluster to Entra ID;
  - managed identities for automation;
  - short-lived registry tokens.
- **Guards are code, so guards are tested.** CI asserts that charts refuse bad input with the expected message. Alert rules have unit tests.
- **Comments explain *why*.** Most comments record a failure mode that actually happened, so the next person does not repeat it.
- **Honest about gaps.** [docs/known-gaps.md](docs/known-gaps.md) lists what is still wrong and what would come next.

## Validate locally

```bash
tools/validate-all.sh          # every check below that the local toolchain supports
```

| Check | Needs |
|---|---|
| `helm lint` + `helm template` for every chart, including the refusal tests | helm 3.17+ |
| `tofu fmt -check` and, where providers can be downloaded, `tofu validate` per stack | OpenTofu 1.8+ |
| Shell syntax, Python compile, JSON parse | bash, python 3 |
| No secrets and no non-placeholder IDs ([tools/scan-secrets.py](tools/scan-secrets.py)) | python 3 |
| Alert-rule unit tests (`promtool test rules`) | promtool or Docker |

## About this sample

- **Anonymised.** Organisation, product, cluster, host, registry, tenant and person names are replaced with neutral placeholders (`example-org`, `product-a`, `example.com`, `hub-dev`, …). Every GUID is an obviously fake repeated-digit value or a well-known public constant, and CI enforces that.
- **Trimmed.**
  - Where the real repositories had many near-identical copies of a pattern (17 service charts, dozens of dashboards), one faithful example is kept.
  - Business logic is replaced by stubs that keep only the platform contract.
- **Corrected where it mattered.** Some shortcuts in the originals are shown in their fixed form, with a comment where the original problem teaches something. Examples:
  - a hard-coded feed token is now a BuildKit secret mount;
  - a promotion step without retry now retries;
  - one gate used `exit 0` inside a script and is now a stage condition.

  What is still open is in [known gaps](docs/known-gaps.md).
