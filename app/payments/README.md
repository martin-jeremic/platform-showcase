# payments

Delivery side of the organisation's **payments** repository: a .NET solution with four deployables
that share domain and contract projects. Card and wallet payment providers, invoicing through the
national e-invoicing service, transactional e-mail, and an operator admin SPA. Business code is not
included.

| Deployable | Image / chart | Notes |
|---|---|---|
| `payments-api` | [src/Api/Dockerfile](src/Api/Dockerfile), [helm/payments-api](helm/payments-api/) | also bakes the admin SPA (node stage) and serves it at `/admin` |
| `payments-invoicing` | [src/Invoicing/Dockerfile](src/Invoicing/Dockerfile) | PDFs with embedded fonts; chiseled-extra for time zones |
| `payments-email` | [src/Email/Dockerfile](src/Email/Dockerfile) | worker with **no HTTP**: `runtime` chiseled base, liveness by process exit |
| `payments-admin-web` | [src/AdminWeb](src/AdminWeb/) | nginx proxies `/pay-admin/api` to the in-cluster API: one origin, no CORS |

## Layout

```
GitVersion.yml, catalog-info.yaml (one Component per deployable)
src/{Api,Invoicing,Email,AdminWeb}/Dockerfile, src/AdminWeb/nginx.conf
helm/payments-api/                    one of three backend charts sharing ONE templates/ directory
pipelines/api/{CI,CD,PR}.yml          one pipeline set per deployable, path-filtered
```

**Shared backend templates.** The three .NET backend charts (api, invoicing, email) carry a
byte-identical `templates/` directory with neutral define names (`payments-backend.*`), so a fix is
copied, not re-applied three times. Each chart is packaged and rendered on its own, so the identical
names never collide. Only `payments-api` is shown.

**ADO bootstrap scripts.** The repository used to carry its own `pipelines/scripts/` (create and
group pipelines, branch policies, environment approvals, cleanup). They now live once, idempotent
and manifest-driven, in [platform/ci-templates/scripts/ado](../../platform/ci-templates/scripts/ado/).

## Key techniques

| Technique | Where |
|---|---|
| Restore cache layer (the source did `COPY . .` before restore, so any change re-downloaded everything) | [src/Api/Dockerfile](src/Api/Dockerfile) |
| App directory stays root-owned; documents on a mounted volume (the source `chown`ed `/app` to the app user) | [src/Api/Dockerfile](src/Api/Dockerfile) |
| ConfigMap of **explicit, hasKey-gated** overridable keys: an absent key keeps the image's baked default, an empty one would blank it | [configmap.yaml](helm/payments-api/templates/configmap.yaml) |
| "Active key id is a values change": key rotation without an image rebuild | [configmap.yaml](helm/payments-api/templates/configmap.yaml) |
| Explicit vault object -> `Section__Key` mapping (dash-only vault names, `__` .NET keys), one plain value per object | [secretproviderclass.yaml](helm/payments-api/templates/secretproviderclass.yaml) |
| Three CSI auth modes: workload identity, node identity (`kubeletClientId` = client id, not object id), service principal on the on-prem hub | [secretproviderclass.yaml](helm/payments-api/templates/secretproviderclass.yaml) |
| Empty fallback Secret for renders without the CSI driver | [secret.yaml](helm/payments-api/templates/secret.yaml) |
| HTTPRoute with explicit `group`/`kind`/`weight`: under SSA the atomic lists were permanently OutOfSync | [httproute.yaml](helm/payments-api/templates/httproute.yaml) |
| Outbound webhooks off by default (a restored database must not start posting) | [values.yaml](helm/payments-api/values.yaml) |
| PR gate: convention checks, build/test, **EF pending-model-changes guard**, helm lint/template; path filters mirrored in the branch policy | [PR.yml](pipelines/api/PR.yml) |
| Build once, deploy-meta artifact, promote dev automatically and services after approval | [CI.yml](pipelines/api/CI.yml), [CD.yml](pipelines/api/CD.yml) |

## Validate

```bash
cd app/payments/helm/payments-api
for v in ci/*.yaml; do helm lint . -f "$v" && helm template t . -f "$v" > /dev/null; done
for e in dev services; do
  helm template payments-api . -f ../../../../gitops/services/apps/payments-api/$e/values.yaml \
    -f ../../../../gitops/services/apps/payments-api/$e/image.yaml > /dev/null
done
```

## KNOWN-GAPS

- `payments-email` has no HTTP and therefore no probe: a worker that hangs without throwing is not
  restarted. A heartbeat file plus an exec probe needs a shell the chiseled image does not have; a
  tiny health listener is the likely fix.
- The chart requests `payments-api--secrets-key-k1`, which the gitops/services seeding list does not
  name yet. Without it the mount fails; the key must be seeded with the same value as
  payments-email's.
- `autoscaling.*` is accepted but no HPA is rendered.
- Invoice documents need an RWX volume shared by invoicing (writer) and API (reader); `sharedDocuments`
  stays off until a storage class is chosen.
