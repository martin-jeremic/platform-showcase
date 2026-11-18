# syntax=docker/dockerfile:1
# payments-invoicing image: consumes payment events, issues invoices to the national e-invoicing
# service and renders PDFs. Build context = repository root.
#   docker build -f src/Invoicing/Dockerfile -t payments-invoicing .

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG VERSION=0.0.0-local
WORKDIR /src
COPY Directory.Build.props Directory.Packages.props ./
COPY src/Invoicing/Payments.Invoicing.csproj src/Invoicing/
COPY src/Domain/Payments.Domain.csproj src/Domain/
COPY src/Contracts/Payments.Contracts.csproj src/Contracts/
RUN dotnet restore src/Invoicing/Payments.Invoicing.csproj
COPY src/Invoicing/ src/Invoicing/
COPY src/Domain/ src/Domain/
COPY src/Contracts/ src/Contracts/
RUN dotnet publish src/Invoicing/Payments.Invoicing.csproj -c Release --no-restore -o /app \
      /p:UseAppHost=false /p:Version=$VERSION

# aspnet, not runtime: the service hosts /healthz/live and /healthz/ready for its probes.
# -extra keeps ICU and tzdata: invoice dates are rendered in the seller's local time zone.
# Fonts used in the PDFs are embedded in the assembly, so the image needs no font packages.
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled-extra AS final
ARG VERSION=0.0.0-local
ARG REVISION=unknown
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION
WORKDIR /app
COPY --from=build /app .
ENV ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_GCConserveMemory=5
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "Payments.Invoicing.dll"]
