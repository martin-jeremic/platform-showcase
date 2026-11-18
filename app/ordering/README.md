# ordering

Delivery side of the organisation's internal **ordering** service: a NestJS API (`ordering-api`)
and a React/Vite SPA (`ordering-app`). Both are company services on the build-once + promote flow.
No application source is included.

## Layout

```
api/Dockerfile          base -> lint-stage -> build-stage -> production-dependencies -> distroless
api/.releaserc.json     semantic-release on main
api/pipelines/CI.yml    version -> lint (Dockerfile target) -> build once
app/Dockerfile          npm ci -> lint-stage / build-stage -> nginx non-root
app/nginx.conf          /health, config.json from /tmp, assets 404 instead of the SPA shell
app/entrypoint.sh       runtime config from env, key names logged only, exec "$@"
```

## Key techniques

| Technique | Where |
|---|---|
| **FIX**: the source Dockerfile set a private-feed token as an `ENV` literal, echoed it in a RUN, and shipped the full build stage (devDependencies, sources, `.npmrc`) as root. Now: BuildKit secret mount for `npm ci`, `npm prune --omit=dev`, distroless `:nonroot` final image with `dist/` and production `node_modules` only | [api/Dockerfile](api/Dockerfile) |
| Builder and runtime on the same Node major and libc, so native modules load | [api/Dockerfile](api/Dockerfile) |
| Lint as a Dockerfile target whose RUN is the gate (the old `docker run` of the lint image could not fail) | [api/Dockerfile](api/Dockerfile), [CI.yml](api/pipelines/CI.yml) |
| Lint and build both gated on `isReleaseReady`, and why | [CI.yml](api/pipelines/CI.yml) |
| `npm ci` instead of `npm install` (the lock file is the contract) | [app/Dockerfile](app/Dockerfile) |
| SPA: non-root nginx, real `/health`, no public host names baked into `server_name` | [app/nginx.conf](app/nginx.conf) |

## Validate

```bash
bash -n app/ordering/app/entrypoint.sh
python -m json.tool app/ordering/api/.releaserc.json > /dev/null
```

## KNOWN-GAPS

- The token that was committed in the source repository must be revoked at the feed; removing it
  from the Dockerfile does not remove it from history.
- The CD pipeline is the standard `promote-stage.yml` caller (see payments) and is not repeated here.
- The charts (`ordering-api`, `ordering-app`) follow the payments-api and hr-app patterns and are not
  repeated.
