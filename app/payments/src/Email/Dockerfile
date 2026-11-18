# syntax=docker/dockerfile:1
# payments-email image: a worker with NO HTTP surface. It consumes "send mail" commands from the
# broker and delivers them through the mail provider. Build context = repository root.
#   docker build -f src/Email/Dockerfile -t payments-email .

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG VERSION=0.0.0-local
WORKDIR /src
COPY Directory.Build.props Directory.Packages.props ./
COPY src/Email/Payments.Email.csproj src/Email/
COPY src/Contracts/Payments.Contracts.csproj src/Contracts/
RUN dotnet restore src/Email/Payments.Email.csproj
COPY src/Email/ src/Email/
COPY src/Contracts/ src/Contracts/
RUN dotnet publish src/Email/Payments.Email.csproj -c Release --no-restore -o /app \
      /p:UseAppHost=false /p:Version=$VERSION

# `runtime`, not `aspnet`: no Kestrel, no ASP.NET shared framework, a smaller image and a smaller
# scan surface. Without HTTP there is no httpGet probe, and the chiseled image has no shell for an
# exec probe either. Liveness is the process itself: since .NET 6 an unhandled exception in a
# BackgroundService stops the host (BackgroundServiceExceptionBehavior.StopHost), the process exits
# non-zero and the kubelet restarts the container. A worker that hangs without throwing is the gap;
# see the payments README, KNOWN-GAPS.
FROM mcr.microsoft.com/dotnet/runtime:10.0-noble-chiseled AS final
ARG VERSION=0.0.0-local
ARG REVISION=unknown
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION
WORKDIR /app
COPY --from=build /app .
ENV DOTNET_GCConserveMemory=5
USER $APP_UID
ENTRYPOINT ["dotnet", "Payments.Email.dll"]
