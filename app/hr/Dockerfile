# syntax=docker/dockerfile:1
# One Dockerfile for the four HR SPAs of an Nx monorepo (portal, admin, absence, employee-book).
# Which app is built is a build argument; CI runs this once per app in a matrix:
#   DOCKER_BUILDKIT=1 docker build --build-arg APP_NAME=portal --secret id=npmrc,src=$HOME/.npmrc -t hr-portal .

# --- build -----------------------------------------------------------------------------------
FROM node:22-alpine AS build
ARG APP_NAME
RUN test -n "$APP_NAME" || (echo "APP_NAME build argument is required" >&2; exit 1)
WORKDIR /app

# The repository's .npmrc holds only registry URLs. The credential for the private feed is a
# BuildKit secret mounted as the USER-level ~/.npmrc for this one RUN: npm merges both files, and
# the credential never lands in a layer, the image history or the build cache. The npm cache mount
# keeps downloaded tarballs between builds on the agent without baking them into the image.
COPY package.json package-lock.json .npmrc ./
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,required=true \
    --mount=type=cache,target=/root/.npm \
    npm ci --prefer-offline --ignore-scripts

COPY . .

# Nx computation cache across builds of the four apps on the same agent (they share libraries).
RUN --mount=type=cache,target=/app/.nx/cache \
    NX_DAEMON=false npx nx build "$APP_NAME" --configuration=production

# Normalise the output path: Angular 17+'s application builder writes dist/apps/<app>/browser,
# older builders wrote dist/apps/<app>. The runtime stage copies one fixed path either way, so an
# app that has not migrated builders yet does not need its own Dockerfile.
RUN if [ -d "/app/dist/apps/${APP_NAME}/browser" ]; then \
      mv "/app/dist/apps/${APP_NAME}/browser" /app/build-output; \
    else \
      mv "/app/dist/apps/${APP_NAME}" /app/build-output; \
    fi

# --- runtime ---------------------------------------------------------------------------------
FROM nginx:stable-alpine AS final
ARG VERSION=0.0.0-local
ARG REVISION=unknown
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION

COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=build /app/build-output /usr/share/nginx/html
# 0755 and root-owned: executable by the nginx user, not writable by it.
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

# FIX: the real image ran as root on port 80 and the entrypoint wrote config.json INTO the web
# root, which only works on a writable root filesystem. Now: non-root on 8080, and the entrypoint
# writes to /tmp/runtime-config (an emptyDir under a read-only root); nginx serves it from there.
EXPOSE 8080
USER 101
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
