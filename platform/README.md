# platform

This area holds everything application teams build on and run on, without owning it.

| Folder | Real repositories | Contents |
|---|---|---|
| [charts](charts) | Product and company platform chart repositories | One Helm chart per shared component, from the CSI driver at sync wave 0 to dashboards at wave 7. That includes the Keycloak server, RabbitMQ, Elasticsearch, MongoDB, Traefik/Gateway API, Argo CD and the whole observability stack |
| [ci-templates](ci-templates) | The shared pipeline-templates repository, plus per-repository template folders | Azure DevOps stage and step templates that every service pipeline calls by tag: build once, record the digest, approval-gated promotion, PR gates, migrations, versioning. Also idempotent ADO bootstrap scripts |

Neither folder decides *where* something runs. That decision lives in [../gitops](../gitops): which chart version, with which values, on which cluster. The Azure resources these charts expect (identities, vaults, storage containers) are created in [../infra](../infra).
