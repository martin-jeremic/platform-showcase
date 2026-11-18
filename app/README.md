# app

How application teams ship to the platform: the **service side of the contract**. Each folder is an
anonymised extract of one real application repository, with its business code replaced by stubs.
What is kept is everything delivery touches: Dockerfiles, Helm charts, pipelines, entrypoints, nginx
configuration, build properties, catalog descriptors and local dev stacks.

| Folder | What the real repository was | Delivery model |
|---|---|---|
| [product-a/](product-a/) | AI logistics SaaS monorepo (.NET, Python, Angular) | variant A: `develop` builds with `az acr build`, `main` promotes by approval into [gitops/apps](../gitops/apps/); dev is push-based |
| [product-b/](product-b/) | Transport management system (.NET, Python agents, Angular) | push-based to one dev namespace; no GitOps folder yet |
| [payments/](payments/) | Multi-service payments repository (.NET + React admin) | variant B: build once on `main`, promote dev then services by approval into [gitops/services](../gitops/services/) |
| [hr/](hr/) | Nx workspace with four Angular SPAs sharing one chart | variant B |
| [ordering/](ordering/) | NestJS API + React SPA | variant B |
| [access/](access/) | .NET permissions API (the i18n API has the same shape) | variant B |

The pipeline templates every service consumes live in [platform/ci-templates/](../platform/ci-templates/) (repository
`platform/shared-templates`, pinned by tag `refs/tags/v1`).

## The platform contract

What every service on the platform does, and where it is shown:

| Rule | Why | Example |
|---|---|---|
| **Configuration from the environment only.** Non-secret config in a ConfigMap, secrets in a Key Vault-synced Secret. No `appsettings.Production.json`, no Base64 blobs | `kubectl get cm,secret` shows exactly what the pod runs with; one image for every environment | [product-a-api configmap](product-a/src/Api/helm/product-a-api/templates/configmap.yaml), [payments-api configmap](payments/helm/payments-api/templates/configmap.yaml) |
| **Options validated at start-up** | a bad value fails the rollout, not the first request an hour later | [Program.cs](product-a/src/Api/Program.cs) (`ValidateOnStart`, plain-JSON-only binder) |
| **Explicit config keys, never `range`** | a key missing from the chart cannot be switched on by any values file; a misspelt key must fail, not become an unread variable | every `configmap.yaml`; the one justified `range` is a list of workloads ([referencedata cronjob.yaml](product-a/charts/product-a-referencedata/templates/cronjob.yaml)) |
| **`required` for keys whose empty value is dangerous** | an empty URL that falls back to `localhost` loads fine and fails later, in the browser or inside the pod | [hr-app configmap](hr/helm/hr-app/templates/configmap.yaml), `config.moduleBaseUrl` in product-a-api |
| **Health: live vs ready.** Liveness never checks a dependency; readiness does | a database blip must take pods out of the Service, not restart every replica at once | [Program.cs](product-a/src/Api/Program.cs), [product-b-api deployment](product-b/deploy/charts/product-b-api/templates/deployment.yaml) |
| **JSON logs to stdout, one shared field contract**, query strings never logged, successful probes dropped | one query across .NET, Python and nginx; no OIDC `?code=` in the log store | [product-a-web nginx.conf](product-a/src/web/nginx.conf), [producta_runtime](product-a/shared/python-runtime/src/producta_runtime/__init__.py) |
| **SIGTERM drain inside the grace period** | no request is cut by SIGKILL | preStop `sleep` action + `HostOptions.ShutdownTimeout`; gunicorn `graceful_timeout` 600 s with `terminationGracePeriodSeconds: 620` |
| **Non-root, numeric UID** (`USER $APP_UID`, `1654`, `101`, distroless `65532`) | `runAsNonRoot: true` can only verify a number | every Dockerfile |
| **Read-only root filesystem**, writes only to an `/tmp` emptyDir | the process cannot modify its own code | nginx temp paths under `/tmp`; entrypoints write runtime config to `/tmp` |
| **Digest-only images**, `pullPolicy: IfNotPresent`, no `latest`, no `imagePullSecrets` where the node identity can pull | a tag is a moving pointer; the chart's image helper fails the render without a digest | `*.image` helper in every `_helpers.tpl` |
| **Secrets through the CSI driver**, one identity per app and environment | no secret passes through a pipeline or a values file | [product-a-api secretproviderclass.yaml](product-a/src/Api/helm/product-a-api/templates/secretproviderclass.yaml) |
| **ConfigMap changes roll pods by checksum; Reloader only for the vault-synced Secret** | Reloader's stamp on a ConfigMap raced Argo's sync and was undone | every `deployment.yaml` |
| **Migrations as a Job**, not a hook and not on start-up: plain Job, named by digest + nonce, `backoffLimit: 0`, no TTL | a failing hook blocked the very build that fixed it; a TTL plus self-heal re-ran DDL forever | [product-a-db](product-a/charts/product-a-db/templates/migration-job.yaml) |
| **No secret in an image, a layer or a log** | BuildKit secret mounts; entrypoints log key names only | [ordering-api Dockerfile](ordering/api/Dockerfile), [hr entrypoint.sh](hr/entrypoint.sh) |

## Patterns and where they live

| Pattern | File |
|---|---|
| Chiseled .NET image, restore cache layer, one publish with `/p:Version`, OCI labels, `DOTNET_GCConserveMemory` | [product-a/src/Api/Dockerfile](product-a/src/Api/Dockerfile) |
| Python: pip-less venv, shared lib installed by path, pip removed, uid 1654, `compileall`, `MALLOC_ARENA_MAX` | [product-a/src/module/Dockerfile](product-a/src/module/Dockerfile) |
| gunicorn with ONE worker and recycling, and why | [gunicorn_conf.py](product-a/shared/python-runtime/src/producta_runtime/gunicorn_conf.py) |
| SPA: private feed via BuildKit secret (or ACR secret build arg), nginx non-root, env.js via subPath | [product-a/src/web](product-a/src/web/) |
| nginx JSON access log: level map, `duration_ms` regex, query stripped, probes suppressed, headers re-asserted per location | [product-a/src/web/nginx.conf](product-a/src/web/nginx.conf) |
| Runtime `<base href>` via `sub_filter`, chart validates `basePath` | [product-b/deploy/web](product-b/deploy/web/), [product-b-web configmap](product-b/deploy/charts/product-b-web/templates/configmap.yaml) |
| Feature-gated Key Vault objects (a missing object fails the whole mount) | [product-a-api secretproviderclass.yaml](product-a/src/Api/helm/product-a-api/templates/secretproviderclass.yaml) |
| Explicit vault object -> `Section__Key` mapping, three CSI auth modes, empty fallback Secret | [payments-api](payments/helm/payments-api/templates/) |
| `hasKey`-gated overridable keys (never blank a baked default) | [payments-api configmap](payments/helm/payments-api/templates/configmap.yaml) |
| HTTPRoute with explicit Gateway API defaults (SSA atomic lists) and per-rule rewrite | [product-a-api httproute.yaml](product-a/src/Api/helm/product-a-api/templates/httproute.yaml) |
| HPA, VPA recommendation-only, PDB only when >1 replica, topology spread with `matchLabelKeys` | [product-a-api templates](product-a/src/Api/helm/product-a-api/templates/) |
| VPA modes explained (Off / Initial / Auto) | [access-api vpa.yaml](access/helm/access-api/templates/vpa.yaml) |
| CronJob per dataset, `ttlSecondsAfterFinished` in the JobSpec, seed Jobs named by spec hash, `--if-empty` | [product-a-referencedata](product-a/charts/product-a-referencedata/templates/) |
| Single-consumer worker: `replicas: 1` + `Recreate`, with the reason | [product-b-worker](product-b/deploy/charts/product-b-worker/templates/deployment.yaml), referencedata consumer |
| NetworkPolicy for an unauthenticated tool host | [product-b-mcp](product-b/deploy/charts/product-b-mcp/templates/networkpolicy.yaml) |
| Owner vs runtime database roles, passwords as psql variables, default privileges | [01-roles-and-database.sql](product-b/deploy/db-bootstrap/01-roles-and-database.sql) |
| Entrypoint writing runtime config without echoing it, `exec "$@"` | [hr/entrypoint.sh](hr/entrypoint.sh) |
| Distroless Node, lint as a Dockerfile target, npm credential as BuildKit secret | [ordering/api/Dockerfile](ordering/api/Dockerfile) |
| Worker without HTTP: `runtime` chiseled base, liveness by process exit | [payments/src/Email/Dockerfile](payments/src/Email/Dockerfile) |
| Directory.Build.props: warnings as errors, central packages, transitive pinning, lock files, the XML double-hyphen trap | [product-b/Directory.Build.props](product-b/Directory.Build.props) |
| Backstage catalog kept out of service folders (no rebuild on a catalog edit) | [product-a/catalog-info.yaml](product-a/catalog-info.yaml) |
| Pipelines: variant A CI / PR / push-based CD with migration stage / config-only CD | [product-a/pipelines/api](product-a/pipelines/api/) |
| Pipelines: variant B build-once + promote, matrix of images sharing one chart | [hr/pipelines](hr/pipelines/), [payments/pipelines/api](payments/pipelines/api/) |
| Refuse placeholders -> migrate -> deploy; nightly suites that gate nothing | [product-b/deploy/pipelines](product-b/deploy/pipelines/) |

## Validate

```bash
cd services
# every chart, with every CI values file
for c in $(find . -name Chart.yaml -exec dirname {} \;); do
  for v in "$c"/ci/*.yaml; do helm lint "$c" -f "$v" && helm template t "$c" -f "$v" > /dev/null; done
done
bash -n hr/entrypoint.sh ordering/app/entrypoint.sh
python -m py_compile product-a/src/module/app.py product-a/shared/python-runtime/src/producta_runtime/*.py
python -m json.tool product-b/global.json > /dev/null
```

The charts were also rendered against every environment's values in `gitops/apps/` and
`gitops/services/` (product-a: stage, demo, prod; company services: dev, services).

## KNOWN-GAPS

- **Bare `values.yaml` renders fail by design.** Charts `required` their per-environment facts, so
  `helm template` with defaults only (as `pr-helm-stage.yml` does first) fails for product-a-api,
  -module, -web, -referencedata, payments-api, hr-app, product-b-api, -agents and -web. The CI values
  files (`ci/*.yaml`) are the intended render inputs, as in chart-testing. Reconciliation with the PR
  template is needed (skip the bare render when `ci/` exists).
- **Probe paths in the GitOps values** use `/health` (and `/healthz` for web) while the stubs serve
  `/health/live` and `/health/ready`; the GitOps values or the apps have to agree on one.
- **`servicePrincipal` CSI auth on the on-prem hub** is a long-lived credential in every namespace;
  workload identity through the hub's OIDC issuer would remove it.
- **Leaked credentials in the source repositories** (an npm token, a PAT) must be revoked, not only
  removed; the showcase carries the fixed pattern, not the rotation.
- **No HPA in the company charts:** `autoscaling.*` is accepted but not rendered (single-node cluster).
- Per-folder gaps are listed in each folder's README.
