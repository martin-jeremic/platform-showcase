# Decision records

Short records of what was chosen, why, what it costs, and what was learned. Each one condenses one or more planning or post-incident documents from the real repositories. Infrastructure-specific notes live next to the code in [infra/docs](../../infra/docs).

| # | Decision |
|---|---|
| [0001](0001-build-once-promote-by-digest.md) | Build once, promote by digest; the approval is the deployment |
| [0002](0002-two-argo-topologies.md) | Hub-and-spoke Argo CD for non-production, an island Argo CD for product production |
| [0003](0003-file-presence-is-deployment.md) | File presence is deployment: git-files ApplicationSets replace hand-written Applications |
| [0004](0004-gitops-values-are-the-single-source.md) | Environment values live only in GitOps; a missing values file is an error |
| [0005](0005-explicit-config-keys.md) | Config keys are written out, never generated with `range` |
| [0006](0006-secrets-key-vault-csi-workload-identity.md) | Secrets: Key Vault through the CSI driver, one workload identity per workload |
| [0007](0007-pat-free-git-access.md) | PAT-free Git access for an on-prem Argo CD through a published OIDC issuer |
| [0008](0008-server-side-apply-and-narrow-ignores.md) | Server-side apply, server-side diff, and narrow `ignoreDifferences` |
| [0009](0009-gateway-api.md) | Gateway API on Traefik instead of Ingress |
| [0010](0010-observability-hub-and-standalone.md) | Observability: OTLP mTLS hub for LAN spokes, standalone stacks elsewhere |
| [0011](0011-alert-notifications-without-smtp.md) | Alert notifications without SMTP and without a mail permission on the tenant |
| [0012](0012-migrations-as-plain-jobs.md) | Database migrations run as a plain Job named by digest |
| [0013](0013-adopt-in-place.md) | Hand-installed Helm releases are adopted in place, not reinstalled |
| [0014](0014-keycloak-as-code.md) | Keycloak as code: one generic module, an exporter, adoption by import |
| [0015](0015-platform-chart-versioning.md) | Platform charts are versioned by per-chart Git tags |
| [0016](0016-scanning-policy.md) | Secret scanning blocks; vulnerability scanning warns |
| [0017](0017-cost-controls.md) | Cost controls: off-hours schedules, honest requests, HA added last |
