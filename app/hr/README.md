# hr

Delivery side of the organisation's **HR** frontends: an Nx workspace with four Angular SPAs
(`portal`, `admin`, `absence`, `employee-book`) built from one Dockerfile and deployed with one
shared chart, `hr-app`, as four Argo Applications (`hr-portal`, `hr-admin`, `hr-absence`,
`hr-employee-book`). The .NET backend (`hr-api`) follows the [access](../access/) shape. No
application source is included.

## Layout

```
Dockerfile          ARG APP_NAME, BuildKit npmrc secret + cache mounts, Angular /browser normalisation
entrypoint.sh       writes assets/config.json from env (to /tmp), then exec "$@"
nginx.conf          non-root 8080, /health, config.json served from /tmp, never cached
.releaserc.json     semantic-release on main
helm/hr-app/        the shared chart
pipelines/CI.yml    build every app once, render the chart against gitops, push the chart
pipelines/CD.yml    promote dev, then services after approval, one job per app
```

## Key techniques

| Technique | Where |
|---|---|
| One Dockerfile, `APP_NAME` build arg; the private feed credential is a BuildKit secret mounted as the user-level `.npmrc` for one RUN | [Dockerfile](Dockerfile) |
| Output-path normalisation (`dist/apps/<app>/browser` vs `dist/apps/<app>`), so builders can migrate one app at a time | [Dockerfile](Dockerfile) |
| **Fixes**: non-root nginx on 8080; config.json written to an emptyDir instead of the web root (works under a read-only root); entrypoint no longer echoes variables or the file; fail-fast on missing values; refuses `"` and `\` that would break the JSON; `exec` so nginx is PID 1 and gets SIGTERM | [entrypoint.sh](entrypoint.sh), [nginx.conf](nginx.conf) |
| A real `/health` (the SPA fallback answered 200 for anything) | [nginx.conf](nginx.conf) |
| ConfigMap with `required` on **every** key: empty values fall back to baked localhost placeholders that load fine and fail in the browser | [configmap.yaml](helm/hr-app/templates/configmap.yaml) |
| One chart, four releases: `nameOverride`/`fullnameOverride` per app, image repository derived from the release name | [_helpers.tpl](helm/hr-app/templates/_helpers.tpl) |
| HTTPRoute with explicit Gateway API defaults | [httproute.yaml](helm/hr-app/templates/httproute.yaml) |
| CI: `isReleaseReady` gate, **every app builds every release** (shared files are invisible to `nx affected`), chart rendered against every app's gitops values before the push | [CI.yml](pipelines/CI.yml) |
| CD: per-app promotion jobs, `Promote_Services` approval-gated, copies the dev digest | [CD.yml](pipelines/CD.yml) |

## Validate

```bash
bash -n app/hr/entrypoint.sh
cd app/hr/helm/hr-app && helm lint . -f ci/ci-values.yaml && helm template hr-portal . -f ci/ci-values.yaml > /dev/null
for a in portal admin absence employee-book; do for e in dev services; do
  helm template hr-$a . -f ../../../../gitops/services/apps/hr-$a/$e/values.yaml \
    -f ../../../../gitops/services/apps/hr-$a/$e/image.yaml > /dev/null; done; done
```

## KNOWN-GAPS

- The base path is baked into each SPA at build time (`baseHref`); moving a route needs a rebuild.
  product-b's runtime `<base href>` rewrite is the pattern that removes this.
- The entrypoint writes JSON with a heredoc and refuses unsafe characters instead of escaping them
  (no `jq` in the image).
