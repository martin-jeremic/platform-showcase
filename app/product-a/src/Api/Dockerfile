# syntax=docker/dockerfile:1
# product-a-api image.
#
# Build context is the MONOREPO ROOT (app/product-a), not this folder:
#   docker build -f src/Api/Dockerfile -t product-a-api .
# The real services also COPY shared class libraries next to the service; the root .dockerignore
# keeps that context small. `az acr build` builds the LAST stage, so `final` stays last;
# docker-compose.dev.yml builds `--target dev` explicitly.
#
# Stages:
#   build - SDK: restore (cached layer) + ONE publish. No separate `dotnet build`: publish
#           compiles, and a second compile only doubles the build time.
#   dev   - local compose only: full runtime + curl for the compose healthcheck.
#   final - production: chiseled runtime, no shell, no package manager, non-root.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG BUILD_CONFIGURATION=Release
# CI passes the resolved semantic version; a local build gets an obvious placeholder.
ARG VERSION=0.0.0-local
WORKDIR /src

# Shared MSBuild properties first: they decide the target framework and therefore the restore.
COPY Directory.Build.props ./

# Project files only, then restore: this layer is reused until a project file changes, so an
# ordinary code change does not re-download every package.
COPY ["src/Api/ProductA.Api.csproj", "src/Api/"]
RUN dotnet restore "src/Api/ProductA.Api.csproj"

COPY src/Api/ src/Api/
# /p:Version stamps the assembly, so /api/info and the logs report the same version as the tag.
RUN dotnet publish "src/Api/ProductA.Api.csproj" \
      -c $BUILD_CONFIGURATION --no-restore -o /app/publish \
      /p:UseAppHost=false /p:Version=$VERSION

# --- dev: local docker-compose only ----------------------------------------------------------
# The compose healthcheck runs curl, which no production runtime image ships. curl lives here and
# NOT in `final`: Kubernetes probes are httpGet and never need it.
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS dev
# Some corporate proxies rewrite apt traffic over plain HTTP; apt then reports "Hash Sum mismatch"
# and `apt-get update` exits 100 on every attempt. No pipelining, no cached responses and treating
# the proxy as broken is the standard remedy; on a clean network it changes nothing.
RUN printf 'Acquire::http::Pipeline-Depth "0";\nAcquire::http::No-Cache "true";\nAcquire::BrokenProxy "true";\n' \
      > /etc/apt/apt.conf.d/99-broken-proxy \
 && apt-get update && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
EXPOSE 8080
ENV DOTNET_GCConserveMemory=5
COPY --from=build /app/publish .
USER $APP_UID
ENTRYPOINT ["dotnet", "ProductA.Api.dll"]

# --- final: production -----------------------------------------------------------------------
# Chiseled = Ubuntu 24.04 with only the runtime's own files: no shell, no apt, no curl, non-root
# by default. `-extra` keeps ICU and tzdata (culture-aware formatting, IANA time zones).
# No shell also means `kubectl exec ... sh` does not work against this pod: use `kubectl debug`
# with an ephemeral container. The migration Job runs this image through its ENTRYPOINT with the
# verb as an argument (no `command:`), so it needs no shell either.
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled-extra AS final
ARG VERSION=0.0.0-local
ARG REVISION=unknown
ARG SOURCE=unknown
# A digest can be traced back to its commit without asking the registry or the pipeline.
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION \
      org.opencontainers.image.source=$SOURCE
WORKDIR /app
EXPOSE 8080
# Trade a little GC throughput for lower retained memory. Under a tight memory limit Server GC
# otherwise parks RSS at its high-water mark and the pod looks like it leaks.
ENV DOTNET_GCConserveMemory=5
COPY --from=build /app/publish .
# Numeric UID (APP_UID=1654, the image's `app` user), so `runAsNonRoot: true` in the pod spec can
# verify it. A user NAME cannot be verified by the kubelet and the pod would be refused.
USER $APP_UID
ENTRYPOINT ["dotnet", "ProductA.Api.dll"]
