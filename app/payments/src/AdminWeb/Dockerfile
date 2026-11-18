# syntax=docker/dockerfile:1
# payments-admin-web: the operator admin SPA as its own nginx image (chart payments-admin-web).
# Build context = this folder (a self-contained npm project, not part of the .NET solution).
#   docker build -t payments-admin-web src/AdminWeb
# Dependencies are public npm packages only, so no registry credential is involved.

FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts
COPY . .
# Vite `base` is /pay-admin/, so index.html references /pay-admin/assets/*.
RUN npm run build

FROM nginx:stable-alpine AS final
ARG VERSION=0.0.0-local
ARG REVISION=unknown
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION
COPY nginx.conf /etc/nginx/nginx.conf
# Served under /pay-admin, so the bundle lives at that path under the web root.
COPY --from=build /app/dist /usr/share/nginx/html/pay-admin
# FIX: the real image listened on 80 as root. Non-root nginx on 8080, writes only under /tmp.
EXPOSE 8080
USER 101
CMD ["nginx", "-g", "daemon off;"]
