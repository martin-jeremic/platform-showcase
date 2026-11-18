# syntax=docker/dockerfile:1
# ordering-api (NestJS). Build context = this folder.
#   DOCKER_BUILDKIT=1 docker build --secret id=npmrc,src=$HOME/.npmrc -t ordering-api .
#   DOCKER_BUILDKIT=1 docker build --secret id=npmrc,src=$HOME/.npmrc --target lint-stage .   # the CI lint gate
#
# FIX compared with the source repository. The real file:
#   * set the private-feed token as an ENV literal in the Dockerfile (so it was in git, in every
#     layer's environment and in `docker inspect` of the running container),
#   * then ECHOED it in a RUN step "to check", which put it in every build log as well,
#   * and shipped the `base` stage as the final image: devDependencies, the full source tree and
#     the .npmrc with the token, running as root.
# A token that was ever committed is leaked, whatever later commits do; it has to be revoked, not
# just removed. Here the credential is a BuildKit secret mounted for the one `npm ci` that needs it,
# and the final image is distroless with production dependencies and dist/ only.
#
# Stages: base -> lint-stage (CI target) / build-stage -> production-dependencies -> final

# One Node major for every stage, and the same major as the distroless runtime below: native
# modules compiled here must load there (both are Debian 12, glibc).
FROM node:22-bookworm-slim AS base
WORKDIR /usr/src/app
# The repository .npmrc holds registry URLs only. The credential is the user-level ~/.npmrc, mounted
# as a secret for this one RUN; npm merges the two files.
COPY package.json package-lock.json .npmrc ./
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,required=true \
    --mount=type=cache,target=/root/.npm \
    npm ci
COPY . .

# The lint gate. The RUN is the check: `docker build --target lint-stage` fails when eslint fails.
# (The old pipeline built this stage and then also `docker run` it, which started the node REPL of
# the base image's default CMD and exited 0: a step that could not fail.)
FROM base AS lint-stage
RUN npm run lint

FROM base AS build-stage
RUN npm run build

# devDependencies out. No credential needed: prune only deletes.
FROM base AS production-dependencies
RUN npm prune --omit=dev

# Distroless: node and its libraries, no shell, no package manager, no npm. :nonroot runs as UID
# 65532. The image's entrypoint is node itself, so CMD is just the script.
FROM gcr.io/distroless/nodejs22-debian12:nonroot AS final
ARG VERSION=0.0.0-local
ARG REVISION=unknown
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION
WORKDIR /usr/src/app
ENV NODE_ENV=production
COPY --from=production-dependencies /usr/src/app/node_modules ./node_modules
COPY --from=build-stage /usr/src/app/dist ./dist
COPY package.json ./
EXPOSE 3000
CMD ["dist/main.js"]
