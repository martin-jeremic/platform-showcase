# Runbooks

Day-2 procedures as they were run. Longer, component-specific procedures sit next to their code and are linked from here.

| Runbook | When |
|---|---|
| [Onboard a service](onboard-service.md) | A team ships a new service to the platform |
| [Onboard a cluster](onboard-cluster.md) | A new spoke is registered with the hub, or a cluster gets a new platform component |
| [Rotate secrets](rotate-secrets.md) | Scheduled or forced rotation of anything stored in Key Vault |
| [Argo CD access](argo-access.md) | Granting, reviewing or debugging who can do what in Argo CD |
| [Restore data](restore.md) | Recovering a database, a blob, a Key Vault object or OpenTofu state |
| [Adopt a hand-installed Helm release](../decisions/0013-adopt-in-place.md) | Bringing an existing release under Argo CD without reinstalling it |
| [AKS minor upgrade](../../infra/docs/aks-minor-upgrade.md) | One Kubernetes minor version, one cluster at a time |
| [Remote state operations](../../infra/docs/state-backend-runbook.md) | Locks, force-unlock, restoring a state version |
