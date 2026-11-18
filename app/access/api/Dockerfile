# syntax=docker/dockerfile:1
# access-api (.NET, SQL Server). Build context = repository root.
#   docker build -f api/Dockerfile -t access-api .

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG VERSION=0.0.0-local
WORKDIR /src
# nuget.config names the private feed; the credential comes from the CI's NuGet authenticate task
# as an environment variable, never from a file in the repository.
COPY nuget.config ./
# Project files first: the restore layer survives ordinary code changes.
COPY src/Access.Api/Access.Api.csproj src/Access.Api/
COPY src/Access.Domain/Access.Domain.csproj src/Access.Domain/
COPY src/Access.Infrastructure/Access.Infrastructure.csproj src/Access.Infrastructure/
RUN dotnet restore src/Access.Api/Access.Api.csproj
COPY src/ src/
# FIX: the source also COPYed appsettings*.json explicitly, including Development settings with a
# local connection string, into the published output. Configuration comes from the environment.
RUN dotnet publish src/Access.Api/Access.Api.csproj -c Release --no-restore -o /app/publish \
      /p:UseAppHost=false /p:Version=$VERSION

# FIX: the source shipped aspnet:10.0 (full Ubuntu, shell, apt) running as root. Chiseled, non-root.
# -extra for ICU: SQL Server collations and culture-aware sorting of user names.
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled-extra AS final
ARG VERSION=0.0.0-local
ARG REVISION=unknown
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION
WORKDIR /app
COPY --from=build /app/publish .
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "Access.Api.dll"]
