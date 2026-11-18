# product-a

Delivery side of the **Product A** monorepo, an AI logistics SaaS: it reads logistics documents
arriving by e-mail, extracts structured bookings with LLMs, lets operators review them, and delivers
the result to each tenant's transport management system. The real monorepo held about fifteen
deployables (.NET services, Python LLM modules, Angular SPAs). One of each kind is shown here, with
stub business logic. **The Angular source tree is not included** (it is product code); the web
folder shows its Dockerfile, nginx configuration, runtime config and chart.

## Architecture (README level)

```
mailboxes ──> ingest worker ──> RabbitMQ ──> platform API (product-a-api) ──> orchestrator
                                               │   ▲                              │
                                               │   │ MCP tools (reference data,   ▼
                                               │   │ tenant lookups)        LLM modules (product-a-module)
                                               ▼   └───────────────────────── llm-product-a / foundry-product-a
                     PostgreSQL: platform schema + one schema per tenant + reference schema
                     audit database: per-tenant, append-only, SHA-256 hash chain
operators ──> product-a-web (SPA) ──> product-a-api        identity: one Keycloak realm per environment
```

- **Tenancy** is by schema and role, not by database: a platform schema, a reference schema
  (loaded by product-a-referencedata) and one schema per tenant created from a template.
- **Audit**: a dedicated database, one schema per tenant, each row chained to the previous by hash,
  written through least-privilege logins.
- **Identity**: Keycloak realms `product-a-dev`, `product-a-stage`, `product-a-demo`, `product-a`.
- **Environments**: dev (push-based, on the `hub-dev` cluster), stage (`product-a-stage`), demo
  (`aks-product-a-demo`), prod (`aks-product-a-prod`), the last three reconciled by Argo CD from
  [gitops/apps](../../gitops/apps/).

## Layout

```
Directory.Build.props, GitVersion.yml, .dockerignore, docker-compose.dev.yml
catalog-info.yaml, catalog/*.yaml          Backstage Location + Components / Resources
shared/python-runtime/                     shared Python lib: JSON log contract + gunicorn config
src/Api/                                   .NET stub (Program.cs, csproj), Dockerfile, chart product-a-api
src/module/                                FastAPI stub, Dockerfile, chart product-a-module
src/web/                                   Dockerfile, nginx.conf, env.js, chart product-a-web
charts/product-a-db/                       migration Job chart (runs the API image)
charts/product-a-referencedata/            CronJob per dataset, seed Jobs, command consumer
pipelines/api/                             CI.yaml, PR.yml, CD.yml, CD-config.yml
```

## Key techniques

| Technique | Where |
|---|---|
| Config groups as plain JSON env vars built with `toJson`; binder refuses non-JSON (no Base64 creeping back); options validated on start | [configmap.yaml](src/Api/helm/product-a-api/templates/configmap.yaml), [Program.cs](src/Api/Program.cs) |
| Secret half of a group as `Section__Key` from the vault, merged by .NET configuration | [deployment.yaml](src/Api/helm/product-a-api/templates/deployment.yaml) |
| `--migrate` / `--verify` / `--seed` verbs in the API image; Job passes `args:` only (chiseled has no shell) | [Program.cs](src/Api/Program.cs), [migration-job.yaml](charts/product-a-db/templates/migration-job.yaml) |
| Digest-only image helper that fails the render without a digest | [_helpers.tpl](src/Api/helm/product-a-api/templates/_helpers.tpl) |
| Feature-gated vault objects; workload identity instead of SP secret / kubelet identity | [secretproviderclass.yaml](src/Api/helm/product-a-api/templates/secretproviderclass.yaml) |
| checksum/config for ConfigMaps, Reloader only for the synced Secret ("stamp races Argo") | [deployment.yaml](src/Api/helm/product-a-api/templates/deployment.yaml) |
| preStop `sleep` action (no `sleep` binary in chiseled) + Kestrel drain inside the grace period | [deployment.yaml](src/Api/helm/product-a-api/templates/deployment.yaml), [Program.cs](src/Api/Program.cs) |
| HTTPRoute: explicit Gateway API defaults, two explicit rules with their own rewrites | [httproute.yaml](src/Api/helm/product-a-api/templates/httproute.yaml) |
| HPA, VPA `Off` (recommendation only), PDB only with >1 replica, topology spread with `matchLabelKeys` (**added**: the real charts had no PDB and no spread) | [templates/](src/Api/helm/product-a-api/templates/) |
| Migration Job: plain Job, `<fullname>-migrate-<digest12>-<runNonce>`, `backoffLimit: 0`, no TTL, own SecretProviderClass/Secret names (prune conflict between Applications) | [charts/product-a-db](charts/product-a-db/templates/) |
| CronJob per dataset, TTL inside `jobTemplate.spec` (SSA rejects it one level up), seed Jobs named by spec hash with `--if-empty`, consumer `replicas: 1` + `Recreate` | [charts/product-a-referencedata](charts/product-a-referencedata/templates/) |
| Python image: pip-less venv, shared lib by path, pip removed, uid 1654, `compileall`, `MALLOC_ARENA_MAX`; gunicorn ONE worker (in-process job store) with recycling and 600 s grace | [src/module/Dockerfile](src/module/Dockerfile), [gunicorn_conf.py](shared/python-runtime/src/producta_runtime/gunicorn_conf.py) |
| SPA image: private feed via BuildKit secret, or ACR `--secret-build-arg` consumed only in the discarded stage (**fix** of a hard-coded token); Azure Artifacts Basic-auth detail | [src/web/Dockerfile](src/web/Dockerfile) |
| nginx: temp paths under `/tmp`, JSON log with level map and `duration_ms` regex, query string stripped (OIDC `?code=`), probes suppressed, headers re-asserted per location, env.js no-cache, hashed assets immutable | [src/web/nginx.conf](src/web/nginx.conf) |
| Root `.dockerignore` anchored per folder, because `az acr build` turns `**/test_*.py` into `.*test_*.py` and drops runtime modules | [.dockerignore](.dockerignore) |
| Catalog outside service folders, so a catalog edit triggers no pipeline | [catalog-info.yaml](catalog-info.yaml) |
| Local stack with `${VAR:-dev-only-not-a-secret}` defaults; the API's `dev` image target carries curl, production does not | [docker-compose.dev.yml](docker-compose.dev.yml) |

### Pipelines (product-a-api)

| File | Does |
|---|---|
| [CI.yaml](pipelines/api/CI.yaml) | convention checks, GitVersion, hermetic tests, then `build-or-promote-stage.yml`: develop = `az acr build` + Trivy + digest recorded for product-a-api AND product-a-db (`secondHelmChartPath`); main = chart push + approval-gated `Promote_Stage` / `Promote_Demo` / `Promote_Prod` |
| [PR.yml](pipelines/api/PR.yml) | convention checks, locked restore/build/tests + EF pending-model guards + Dockerfile lint/scan, helm lint/template of both charts |
| [CD.yml](pipelines/api/CD.yml) | push-based dev: `RefusePlaceholders` -> `Migrate_Dev` (Job, same digest, `--wait-for-jobs`) -> `Deploy_Dev`; `runMigrations` escape hatch as a run parameter |
| [CD-config.yml](pipelines/api/CD-config.yml) | values-only redeploy of dev, chart and image read back from the release (no `--reuse-values`) |

**E2E:** the end-to-end suite (Playwright against the real stack) is not part of any PR. It needs the
whole stack and a browser and runs nightly against dev
([platform/ci-templates/examples/e2e-nightly.yml](../../platform/ci-templates/examples/e2e-nightly.yml)); a red
nightly is triaged, it never blocks a merge.

## Validate

```bash
cd app/product-a
for c in src/Api/helm/product-a-api src/module/helm/product-a-module src/web/helm/product-a-web charts/product-a-db charts/product-a-referencedata; do
  helm lint "$c" -f "$c/ci/ci-values.yaml" && helm template t "$c" -f "$c/ci/ci-values.yaml" > /dev/null
done
python -m py_compile src/module/app.py shared/python-runtime/src/producta_runtime/*.py
# against the GitOps values
helm template product-a-api src/Api/helm/product-a-api \
  -f ../../gitops/apps/apps/product-a-api/stage/values.yaml -f ../../gitops/apps/apps/product-a-api/stage/image.yaml > /dev/null
```

## KNOWN-GAPS

- Only one service's pipelines are shown (the API with its Job chart). The module, web and
  referencedata pipelines follow the same templates; the web image needs `secretBuildArgs: {NPM_TOKEN: ...}`.
- The referencedata chart iterates over `datasets` (`range`), the one exception to the no-`range`
  rule; its PR helm stage must run with `forbidRange: false`.
- On dev, schema-before-code is a pipeline ordering. In the GitOps environments nothing orders the
  product-a-db and product-a-api Applications; the migration lint (expand/contract) is the only
  guard, and a per-tenant schema gate on the consume path was still open.
- A Complete migration Job says "this digest ran once", not "the database is aligned"; there is no
  automated drift check against the migration history tables.
- No Angular source, no test projects, no shared .NET libraries: the paths referenced by the
  pipelines (`tests/Api.Tests/...`) are illustrative.
