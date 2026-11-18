# infra

OpenTofu for the Azure estate behind both product lines. This folder is an anonymised,
trimmed but faithful rendering of two real repositories:

- **`product-a-iac`**: the AI logistics SaaS ("Product A"). It holds a disposable demo
  AKS, a production AKS with Argo CD bootstrap, the AI Foundry deployment, alert
  delivery and the product's Keycloak realms. These are the `product-a/` stacks.
- **`org-iac`**: the organisation's shared platform. It holds the production AKS for
  internal services, the shared PostgreSQL and SQL servers, the registries and vaults,
  backups, federated workload identities and the organisation's Keycloak realms.
  Almost all of it was built in the portal first and **adopted by import**. These are
  the `org/` stacks.

The in-cluster layer (ingress, TLS, observability, applications) is out of scope here.
It lives in `platform/charts/`, `gitops/platform/` and `gitops/apps/`. What crosses
the boundary is called out where it happens: client IDs, vault object names, the Argo
CD release name, and federated subjects.

## Layout

```
tfstate-bootstrap/            shared state account (local state on purpose)
product-a/
  aks-demo/                   disposable demo cluster, shape A/B, start/stop automation
  aks-prod/                   production cluster, BYO VNet, HA seam, PG + LTR, Argo CD bootstrap
  ai-foundry/                 AIServices account, Foundry project, model deployment
  alerting/                   Alertmanager credentials: Entra app, Teams Logic Apps, vault objects
    exchange/                 Set-AlertingSenderScope.ps1 (Exchange RBAC for Applications)
  keycloak/
    modules/realm/            hand-written product realm module
    dev/  prod/               one root per realm
    bootstrap-provisioner.sh  seeds the per-realm provisioner client
org/
  aks-prod/                   Entra-only cluster, audit log, power schedule, access groups
  postgres/                   shared server, app roles via the postgresql provider
  mssql/                      adopted SQL server, write-only password held inert
  backup/                     off-cluster dump storage, no-delete identity
  registry/                   ACR import stack, grants as data
  keyvaults/                  vault import stack, grants as data, purge protection
  identities/argocd-git/      on-prem hub -> Azure DevOps via a self-published OIDC issuer
  identities/backstage/       same shape + Key Vault + generated session secret
  identities/trivy/           AcrPull-only scanner identity
  keycloak/
    modules/realm/            generic, exporter-driven realm module
    services/                 production instance root (generated example)
scripts/
  keycloak/                   kc_admin.py, kc_bootstrap.py, kc_export.py (stdlib only)
  postgres/                   create-app-roles.sql (idempotent, passwords via env)
docs/                         decision records and runbooks
```

The real repositories had more stacks than this: product-a also had stage and demo
Keycloak roots, and the org repository had a dev Keycloak root, two retired Keycloak
generations and an alerting copy. Repeated patterns appear once here.

## Conventions

| Convention | Where | Why |
|---|---|---|
| **One state blob per stack** in one hardened account (versioning, soft delete, `prevent_destroy`, `CanNotDelete` lock) | [`tfstate-bootstrap`](tfstate-bootstrap/main.tf), every `backend` block | Durable, lockable, shared state; a stack's `destroy` can never reach it. Runbook: [`docs/state-backend-runbook.md`](docs/state-backend-runbook.md). The two real repositories each had their own account; here one bootstrap serves both. |
| **Lock files committed** | `.terraform.lock.hcl` per stack | Provider hashes pinned for every platform (`h1` and `zh`), generated with `tofu init -backend=false`. |
| **`prevent_destroy` + `CanNotDelete` lock on anything that holds data** | [`org/mssql`](org/mssql/main.tf), [`org/backup`](org/backup/main.tf), [`org/keyvaults`](org/keyvaults/main.tf), [`tfstate-bootstrap`](tfstate-bootstrap/main.tf) | They fail in different directions: one stops OpenTofu, the other the portal and CLI. Registries get no lock: images are not the only copy of anything. |
| **Kubernetes versions are minor aliases**, validated; every pool sets `orchestrator_version` | [`org/aks-prod/variables.tf`](org/aks-prod/variables.tf), [`product-a/aks-prod/aks.tf`](product-a/aks-prod/aks.tf) | A patch pin fights the patch channel; a pool without `orchestrator_version` silently stays a minor behind. [`docs/aks-minor-upgrade.md`](docs/aks-minor-upgrade.md). |
| **Import, don't rebuild** (11 rules) | `org/*` | [`docs/import-methodology.md`](docs/import-methodology.md). |
| **Provider aliasing to the shared-services subscription** | [`product-a/aks-prod/main.tf`](product-a/aks-prod/main.tf), [`product-a/alerting/providers.tf`](product-a/alerting/providers.tf) | The registries and vaults live in another subscription of the same tenant; data sources and grants go through `azurerm.shared`. IDs are always looked up, never pasted. |
| **Consumer owns the grant** | kubelet, Trivy and Backstage grants live with the identity, not with the registry/vault stack | One owner per assignment; the registry and vault stacks list what other states own. |
| **Committed defaults are the managed set** | `clusters`, `teams_channels`, `role_assignments`, `firewall_rules`, `kubernetes_version`, schedules | A git-ignored tfvars that overrides them is a change no review saw. `*.tfvars.example` holds only non-secret knobs. |
| **Feature switches are `count`, not comments** | [`product-a/aks-demo/automation.tf`](product-a/aks-demo/automation.tf), [`org/aks-prod/nodepools.tf`](org/aks-prod/nodepools.tf) | Stable addresses; clean removal; no edit to turn back on. |
| **No secret outputs** | every stack | Generated secrets go straight into Key Vault; outputs carry names, IDs and commands to read them. |

## Stacks

| Stack | What it shows |
|---|---|
| [`tfstate-bootstrap`](tfstate-bootstrap/) | Local state on purpose, `backend_config` output, lock + versioning + soft delete. |
| [`product-a/aks-demo`](product-a/aks-demo/) | Shape A/B switch touching node pools only; ephemeral-OS SKUs with managed-disk fallback; static egress IP for the DB firewall; ingress PIP outside `MC_*` plus Network Contributor; count-gated start/stop with a 3-action custom role and DST-derived first run; Data Protection blob backup coupled to PITR; Trivy federated identity; PG with extension allowlist and `prevent_destroy`. |
| [`product-a/aks-prod`](product-a/aks-prod/) | BYO VNet with reserved subnets; `ha` seam vs create-time-immutable settings; four pools with reasons (critical-only system, infra floor 2, monitoring pinned at 1 by the 4-data-disk limit); patch + NodeImage channels in maintenance windows; private-by-default API server; PG SameZone HA behind a precondition; vaulted LTR with derived anchor, tiered retention, create-before-destroy rename and a `protection_state` postcondition; the 406 explanation and undelete/resume runbook; storage PITR coupled to soft delete; diagnostics to blob; per-container workload identities for Loki/Tempo; second ACR grant as its own resource; Argo CD `helm_release` with wave-5 hand-off and `ignore_changes = all`. |
| [`product-a/ai-foundry`](product-a/ai-foundry/) | AIServices with `project_management_enabled`, azapi project, model deployment; **no key outputs**. |
| [`product-a/alerting`](product-a/alerting/) | Entra app with **zero Graph permissions** and Mail.Send scoped in Exchange; `time_rotating` + `create_before_destroy` secret rotation with a duration precondition; `check` blocks for secret expiry and Teams authorisation (via azapi); Logic App that answers 200/502 synchronously; `audiences` built with `merge(map, [list of maps]...)`; the fail-closed Exchange script. |
| [`product-a/keycloak`](product-a/keycloak/) | `realm_id` local (adopting vs greenfield); `composite_roles = []`; authoritative scope lists; exhaustive `keycloak_user_roles`; `removed` for replaced resources; moved-then-removed of a `for_each` instance; `import` with `for_each`; bootstrap operator with `ignore_changes = [initial_password, required_actions]`. |
| [`org/aks-prod`](org/aks-prod/) | Entra-only (local accounts off), admin group, a group per namespace, Cluster User Role; audit log (kube-audit-admin + guard) with a quota; 3-action power role; one parameterised REST runbook with DST-correct start time and lowercase parameter keys; minor-alias validation; auto-upgrade channel with windows inside running hours; declared egress IP. |
| [`org/postgres`](org/postgres/) | `cyrilgdn/postgresql` role + grant + password into Key Vault (rotate with `-replace`); firewall as a variable map. |
| [`org/mssql`](org/mssql/) | Adopted server; write-only admin password held inert; per-DB `for_each`; lock in the second commit. |
| [`org/backup`](org/backup/) | Keys off + `storage_use_azuread`; GRS; versioning; Cool/Cold/delete lifecycle; federated UAMI; custom role with read/write/add and **no delete**, scoped to the container. |
| [`org/registry`](org/registry/) | Every live flag stated; grants keyed `principal\|role\|registry` with lookups and exactly-one-of validation; [`imports.tf.example`](org/registry/imports.tf.example). |
| [`org/keyvaults`](org/keyvaults/) | Vault map with `network_acls` via `[*]`; vault-or-RG grant scope; purge protection on. |
| [`org/identities`](org/identities/) | Federation to an **on-prem** cluster's self-published issuer; Azure DevOps entitlement `express`; Backstage session secret; AcrPull-only Trivy identity. |
| [`org/keycloak`](org/keycloak/) | Generic module carrying the provider-5.9 lessons; a generated root; generated imports. |

## How to validate

```bash
cd infrastructure
tofu fmt -check -recursive .
for d in $(find . -name '*.tf' -not -path '*/.terraform/*' -not -path '*/modules/*' -printf '%h\n' | sort -u); do
  (cd "$d" && tofu init -backend=false -input=false >/dev/null && tofu validate) || echo "FAILED: $d"
done
python -m py_compile scripts/keycloak/*.py
bash -n product-a/keycloak/bootstrap-provisioner.sh
bash product-a/keycloak/bootstrap-provisioner.sh --self-test   # needs jq
```

The `.example` files (`imports.tf.example`, `imports-org.tf.example`) validate when
copied to `.tf` next to their root.

## KNOWN-GAPS

- **The kubelet identity holds Key Vault Secrets User** on both product clusters and
  the org cluster. Every pod on a node can read the vault through IMDS. The
  per-workload replacement is shown for Loki/Tempo
  ([`identity-workload.tf`](product-a/aks-prod/identity-workload.tf)), backups and
  Trivy, but the CSI mounts of the identity provider, broker and search engine still
  use the kubelet identity.
- **The product prod cluster keeps local accounts enabled.** The Helm provider
  authenticates with the local admin kubeconfig to bootstrap Argo CD. Moving to
  Entra-only means `kube_admin_config` plus kubelogin.
- **PostgreSQL servers use public access with firewall rules.** The product prod VNet
  reserves the delegated subnet for VNet injection, but that is create-time only, so
  the move is a migration.
- **Password auth is still on** for PostgreSQL (mixed mode on product prod, password
  only on the org server) until every consumer uses Entra tokens.
- **The org registry has the admin user enabled** (one shared push/pull password).
  Turning it off waits for confirmation that nothing still logs in with it.
- **Vault network ACLs are open** (`default_action = Allow`), recorded as found.
- **The state account keeps shared keys enabled.** The backend reads state with a key
  unless everyone uses `use_azuread_auth`.
- **AI Foundry key auth is still enabled** (`local_auth_enabled`); keys are read at
  runtime, not output, but Entra-only is the end state.
- **Open Keycloak findings** that the exporter marks in the generated realm files:
  - realm-management roles in `default-roles-<realm>` (every user can administer the
    realm);
  - brute-force protection off on the org realms;
  - public SPA clients without PKCE;
  - a wildcard `web_origins = ["+"]`;
  - service accounts holding realm-management roles whose owners still have to
    confirm them.
- **The audit writer DB role** is created by the service's own migration script, not
  by IaC; its correctness depends on that script being run.
- **Org cluster:** single node, every workload one replica; the two-node plan's
  prerequisites (replicas, spread, PDBs, PriorityClasses) are tracked in
  [`docs/two-node-ha.md`](docs/two-node-ha.md). The database PVC storage class
  reclaim policy is a chart concern.
- **Network contributor scope** for the org ingress IP is the resource group, not the
  IP. Narrowing it needs the ingress chart to select the IP by name.
- **No backup alerting** is wired for the Data Protection vaults yet (an alert
  processing rule plus action group); the `protection_state` postcondition catches
  stopped protection only at plan time.
- **`kc_export.py` is trimmed**: it covers settings, scopes, roles, groups, clients,
  brokers and flows. Organisations, user profile, events and required actions are not
  exported, and the trimmed module does not model them.
- **`bootstrap-provisioner.sh --self-test`** needs `jq` and was not run on the machine
  that produced this folder; `bash -n` was.
