# syntax=docker/dockerfile:1
# payments-api image. Build context = repository root (Directory.*.props and project references):
#   docker build -f src/Api/Dockerfile -t payments-api .
#
# The API also serves the operator admin SPA at /admin (static files + SPA fallback), so the image
# builds the SPA in a node stage and bakes its dist/ into wwwroot. `docker build` alone produces a
# complete image: no manual pre-build step that someone forgets on a release.
# (The same SPA is ALSO shipped standalone as payments-admin-web, see src/AdminWeb.)

# --- spa: admin SPA (React/Vite). Public npm packages only, so no registry credential. ----------
FROM node:22-alpine AS spa
WORKDIR /spa
COPY src/AdminWeb/package.json src/AdminWeb/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts
COPY src/AdminWeb/ ./
RUN npm run build

# --- build -----------------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG VERSION=0.0.0-local
WORKDIR /src
# FIX: the real file did `COPY . .` before restore, so ANY change (a README, a test) invalidated the
# restore layer and re-downloaded every package. Props and project files first, restore, then code.
COPY Directory.Build.props Directory.Packages.props ./
COPY src/Api/Payments.Api.csproj src/Api/
COPY src/Domain/Payments.Domain.csproj src/Domain/
COPY src/Contracts/Payments.Contracts.csproj src/Contracts/
RUN dotnet restore src/Api/Payments.Api.csproj
COPY src/Api/ src/Api/
COPY src/Domain/ src/Domain/
COPY src/Contracts/ src/Contracts/
RUN dotnet publish src/Api/Payments.Api.csproj -c Release --no-restore -o /app \
      /p:UseAppHost=false /p:Version=$VERSION

# --- final -----------------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled-extra AS final
ARG VERSION=0.0.0-local
ARG REVISION=unknown
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION
WORKDIR /app
COPY --from=build /app .
COPY --from=spa /spa/dist ./wwwroot/admin
# FIX: the real image ran `chown -R app:app /app` so the app could write invoice documents next to
# its own binaries. The app directory now stays root-owned (the process cannot modify its own code),
# and documents go to /data/documents, a volume the chart mounts (read-only for the API: the
# invoicing service writes, the API only serves).
ENV ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_GCConserveMemory=5
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "Payments.Api.dll"]
