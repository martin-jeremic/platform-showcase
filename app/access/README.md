# access

Delivery side of the organisation's **access** (permissions) API: a .NET service on SQL Server that
manages application permissions on top of the identity provider. The **i18n** API has the same
shape and is not repeated. No application source is included.

## Layout

```
api/Dockerfile               restore cache layer, chiseled-extra, non-root
docker-compose.dev.yml       local SQL Server, RabbitMQ, Keycloak
helm/access-api/             chart with the VPA template
pipelines/PR.yml             unit vs integration suites, coverage, helm validation
```

## Key techniques

| Technique | Where |
|---|---|
| VPA template with the update modes explained (`Off` recommends, `Initial` sizes new pods only, `Auto` evicts), mode validated at render | [vpa.yaml](helm/access-api/templates/vpa.yaml) |
| hasKey-gated `env:` keys; a list value joined into one variable instead of `__0..n` indexes | [configmap.yaml](helm/access-api/templates/configmap.yaml) |
| One plain vault value per object, three CSI auth modes (as payments-api) | [deployment.yaml](helm/access-api/templates/deployment.yaml) |
| **FIX**: the source image ran full `aspnet` as root and published `appsettings.Development.json` with a local connection string | [api/Dockerfile](api/Dockerfile) |
| **FIX**: the source compose file repeated one SA password literal in five places and used a locally built Keycloak image; now `${MSSQL_SA_PASSWORD:?}` (no default), healthchecks, public images | [docker-compose.dev.yml](docker-compose.dev.yml) |
| PR with unit and integration as separate named suites, coverage on | [PR.yml](pipelines/PR.yml) |

## Validate

```bash
cd app/access/helm/access-api && helm lint . -f ci/ci-values.yaml && helm template t . -f ci/ci-values.yaml > /dev/null
```

## KNOWN-GAPS

- `pr-dotnet-stage.yml` has no NuGet authentication step for the private feed yet.
- Integration suites that need a real SQL Server run locally only; no CI agent has a database.
