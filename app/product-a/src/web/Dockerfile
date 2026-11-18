# syntax=docker/dockerfile:1
# product-a-web image: an Angular SPA built with Nx, served by nginx as non-root.
#
# The Angular source tree is NOT part of this showcase (it is product code); this file shows the
# delivery side only. Build context is this folder. Two ways to hand in the private-feed credential:
#   local / buildx:  DOCKER_BUILDKIT=1 docker build --secret id=npmrc,src=$HOME/.npmrc -t product-a-web src/web
#   az acr build:    ... --secret-build-arg NPM_TOKEN=<token>   (build-or-promote-stage secretBuildArgs)
#
# FIX compared with the source repository: the real file wrote the private-feed credential into a
# RUN line as a literal (a "stopgap" after the build-arg plumbing delivered an empty token). A
# literal in a Dockerfile is in git history forever and in the image's build metadata, whatever the
# RUN does afterwards. Now:
#   * preferred: a BuildKit secret mount. It exists only for the one RUN that needs it and is never
#     written to a layer, the history or the build cache.
#   * `az acr build` has no secret mount, only `--secret-build-arg`, which ACR keeps out of its logs.
#     A build arg IS recorded in the history of the stage that declares it, so it is declared in
#     the `build` stage only, which is discarded: nothing of it reaches the final image.

# --- build -----------------------------------------------------------------------------------
FROM node:24-slim AS build
WORKDIR /app
ENV NX_DAEMON=false \
    NX_NO_CLOUD=true \
    CI=true
ARG NPM_TOKEN=""
# Host and path of the private UI-component feed (<artifacts-host>/example-org/_packaging/<feed>/npm),
# passed by CI. No credential in it.
ARG NPM_FEED=""

COPY package.json package-lock.json ./
# Azure Artifacts wants Basic auth for npm (a username plus the base64 token as _password).
# _authToken (Bearer) passes the metadata request and then 401s on the tarball download, because
# tarballs are served from the path WITHOUT /registry/, so the entry is written for both paths.
# The user-level ~/.npmrc is assembled, used and deleted inside ONE RUN, so it never lands in a
# layer. --ignore-scripts: dependency install scripts do not run with the credential in reach.
RUN --mount=type=secret,id=npmrc,target=/run/secrets/npmrc,required=false \
    --mount=type=cache,target=/root/.npm \
    set -eu; \
    if [ -s /run/secrets/npmrc ]; then \
      cp /run/secrets/npmrc /root/.npmrc; \
    elif [ -n "$NPM_TOKEN" ]; then \
      [ -n "$NPM_FEED" ] || { echo "NPM_FEED build arg is required with NPM_TOKEN" >&2; exit 1; }; \
      pw="$(printf '%s' "$NPM_TOKEN" | base64 -w0)"; \
      for suffix in /registry/ /; do \
        echo "//${NPM_FEED}${suffix}:username=ci" >> /root/.npmrc; \
        echo "//${NPM_FEED}${suffix}:_password=${pw}" >> /root/.npmrc; \
        echo "//${NPM_FEED}${suffix}:email=ci-bot@example.com" >> /root/.npmrc; \
      done; \
    else \
      echo "No npm credential: pass --secret id=npmrc or --secret-build-arg NPM_TOKEN" >&2; \
      exit 1; \
    fi; \
    npm ci --ignore-scripts; \
    rm -f /root/.npmrc

COPY . .
ARG NX_CONFIGURATION=production
RUN node node_modules/.bin/nx build web --configuration=$NX_CONFIGURATION

# --- final -----------------------------------------------------------------------------------
# The maintained stable branch. A pinned mainline tag (1.27-alpine) stopped receiving rebuilds
# once superseded, so its Alpine layer stayed frozen with every CVE fixed after it.
FROM nginx:stable-alpine AS final
ARG VERSION=0.0.0-local
ARG REVISION=unknown
ARG SOURCE=unknown
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION \
      org.opencontainers.image.source=$SOURCE

COPY nginx.conf /etc/nginx/nginx.conf
# Angular's application builder writes to dist/<app>/browser. The site stays root-owned and
# read-only for nginx, so the serving process cannot rewrite the JavaScript it serves. (A
# `chown -R` used to hand it to the runtime user and, as its own layer, stored the bundle twice.)
COPY --from=build /app/dist/web/browser /usr/share/nginx/html
# Default runtime config; a cluster mounts the chart's ConfigMap over this one file.
COPY env.js /usr/share/nginx/html/env.js

EXPOSE 8080
# For `docker run` and compose only; Kubernetes ignores HEALTHCHECK and uses the chart's probes.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz > /dev/null || exit 1

# Numeric: the image's `nginx` user, so runAsNonRoot can verify it. nginx writes only under /tmp
# (see nginx.conf), which the chart mounts as an emptyDir under a read-only root.
USER 101
CMD ["nginx", "-g", "daemon off;"]
