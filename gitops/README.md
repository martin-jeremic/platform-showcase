# gitops

These are the Argo CD repositories. Each one holds data that answers a single question: **what runs where**. None of them contains a chart or a line of application code. They reference charts by version and images by digest.

| Folder | Real repository | Answers | Written by |
|---|---|---|---|
| [platform](platform) | Platform GitOps (hub and island) | Which platform component, at which chart tag, runs on which cluster, with which values | People, through reviewed PRs. The island cluster also gets descriptor bumps from chart CI |
| [apps](apps) | Product A application GitOps | Which image digest and chart version of each Product A service runs in stage, demo and prod | The approval-gated promotion pipeline (`image.yaml`, `release.yaml`), and people (`values.yaml`) |
| [services](services) | Company services GitOps | The same, for the company services in `dev` and `services` | The same split as `apps` |

There are two Argo CD topologies, and each repository renders separate targets for them:
- **Hub.** The hub Argo CD reconciles every non-production cluster and the company production cluster.
- **Island.** Product A's production cluster runs its own Argo CD, which reconciles only that cluster.

See [ADR-0002](../docs/decisions/0002-two-argo-topologies.md) and the [delivery flow](../docs/delivery-flow.md).
