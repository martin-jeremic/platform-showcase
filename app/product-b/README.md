# product-b

Deploy-model highlights of **Product B**, a transport management system for road freight, built
later than Product A and from scratch. Product A's document intake becomes one intake channel of it.
Only delivery files are shown: build properties, nginx, six charts, the database bootstrap and the
pipelines.

## The layering rule

```
src/1-domain/     the deterministic TMS. Knows nothing about agents or HTTP.
src/2-platform/   deterministic infrastructure serving the domain (API, MCP host, worker, migrator)
src/3-agents/     the AI workflow layer (Python). Delete this folder: the product still ships.
src/4-web/        the Angular workbench and the driver app
```

**Nothing in `1-domain` or `2-platform` may reference `3-agents`.** The agents propose, draft and
explain by calling the domain's own tools (through the MCP host), behind approval gates, with
everything recorded. The rule is asserted by architecture tests (nightly), not trusted, and the
deployment mirrors it:

- `product-b-agents` holds **no** database, broker or storage credential; its only secret is its own
  Keycloak client secret ([values.yaml](deploy/charts/product-b-agents/values.yaml)).
- `product-b-mcp` authenticates nobody, so a NetworkPolicy admits only the agents' pods
  ([networkpolicy.yaml](deploy/charts/product-b-mcp/templates/networkpolicy.yaml)).
- The agent layer has its own pipeline and chart; removing both leaves a complete product.

## Status vocabulary

The repository reports every part with one of three words, and nothing else:

| Status | Means |
|---|---|
| **built and tested** | exists and was exercised the way production would use it (for example: image built and run, readiness 503 with the database down, Worker exit 0 on SIGTERM) |
| **built and unverified** | exists but was never run in that form (for example: pipelines never registered, web image never built) |
| **not started** | does not exist yet |

"Done" is not a status. The Helm charts here were *built and tested* with `helm lint` and
`helm template`, never installed; the pipelines were *built and unverified*.

## Layout

```
global.json, Directory.Build.props, Directory.Packages.props
deploy/web/nginx.conf, deploy/web/base-href.conf
deploy/charts/product-b-{api,mcp,worker,agents,web,db}/
deploy/db-bootstrap/01-roles-and-database.sql
deploy/pipelines/CI.yaml, CD.yml, PR.yml, nightly.yml
```

## Key techniques

| Technique | Where |
|---|---|
| Warnings as errors (analysers assert determinism), central package management with **transitive pinning**, lock files (locked restore + licence scan of transitive packages), Deterministic + `ContinuousIntegrationBuild` on `TF_BUILD` | [Directory.Build.props](Directory.Build.props) |
| `InvariantGlobalization=false` and why: IANA zones need ICU; determinism comes from banning the ambient culture instead | [Directory.Build.props](Directory.Build.props) |
| The XML comment double-hyphen trap (TargetFramework silently read as empty) | [Directory.Build.props](Directory.Build.props) |
| SDK pinned with `rollForward: latestPatch` | [global.json](global.json) |
| Runtime `<base href>` through `sub_filter`, one image for any path prefix; chart fails unless `basePath` starts and ends with `/` | [nginx.conf](deploy/web/nginx.conf), [product-b-web configmap](deploy/charts/product-b-web/templates/configmap.yaml) |
| Readiness = a real database check; PDB only with more than one replica | [product-b-api](deploy/charts/product-b-api/templates/) |
| Worker: `replicas: 1` (not a value) + `Recreate`, because the drains claim no rows | [product-b-worker](deploy/charts/product-b-worker/templates/deployment.yaml) |
| Migration Job with `command: ["dotnet", "ProductB.Migrator.dll"]`: exec without a shell | [product-b-db](deploy/charts/product-b-db/templates/migration-job.yaml) |
| Owner role vs runtime role, passwords as psql variables, default privileges for future tables | [01-roles-and-database.sql](deploy/db-bootstrap/01-roles-and-database.sql) |
| `refuse-placeholders` -> migration -> deploy; **no** "deploy past a failing migration" switch | [CD.yml](deploy/pipelines/CD.yml) |
| Heavy suites nightly, gating nothing; `always: true`; UI schedules override YAML | [nightly.yml](deploy/pipelines/nightly.yml) |

## Validate

```bash
cd app/product-b
for c in deploy/charts/*/; do helm lint "$c" -f "$c/ci/ci-values.yaml" && helm template t "$c" -f "$c/ci/ci-values.yaml" > /dev/null; done
python -c "import json; json.load(open('global.json'))"
```

## KNOWN-GAPS

- `build-stage.yml` pushes one chart; product-b's CI pushes the companion `product-b-db` chart in an
  inline stage until the template takes a companion chart.
- No GitOps folder yet: dev only, push-based. Stage and production are "not started".
- The Worker cannot scale out until its drains claim rows (`FOR UPDATE SKIP LOCKED`).
- `product-b-mcp`'s NetworkPolicy protects nothing on a CNI that does not enforce policies.
- Not included: `GitVersion.yml` (same shape as product-a's) and `deploy/docker-compose.dev.yml`
  referenced by the pipelines; the Python agents' Dockerfile (same pattern as product-a-module).
