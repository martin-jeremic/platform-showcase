# syntax=docker/dockerfile:1
# ordering-app (React/Vite SPA). Build context = this folder.
#   docker build -t ordering-app .
#   docker build --target lint-stage .        # the CI lint gate
# Public npm packages only, so no registry credential.

# FIX: `npm ci`, not `npm install`. install may rewrite the lock file and resolve newer versions
# than the ones reviewed; ci installs exactly the lock file or fails.
FROM node:22-alpine AS install-stage
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts
COPY . .

# The RUN is the gate: the build fails when lint fails. (A CMD here only ran when someone ran it.)
FROM install-stage AS lint-stage
RUN npm run lint

FROM install-stage AS build-stage
RUN npm run build

FROM nginx:stable-alpine AS final
ARG VERSION=0.0.0-local
ARG REVISION=unknown
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION
COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=build-stage /app/dist /usr/share/nginx/html
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
# Non-root on 8080; config.json is written to /tmp (see entrypoint.sh and nginx.conf).
EXPOSE 8080
USER 101
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
