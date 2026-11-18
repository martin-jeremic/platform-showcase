# gitops/services

The Argo CD GitOps repository for the organisation's own business services: HR, payments, access management, localisation (i18n) and ordering. **One ApplicationSet** delivers every one of them to two environments:

| Env folder | Cluster | Addressed as | Host |
|---|---|---|---|
| `dev` | `hub-dev`, the on-prem hub where Argo CD itself runs (ns `argocd-hub`) | `server: https://kubernetes.default.svc` | `dev.example.com` |
| `services` | `aks-org-prod`, the production spoke | `name: aks-org-prod` | `services.example.com` |

The services came from push-based CDs (`helm upgrade` from the pipeline, with Key Vault secrets fetched into `--set`). They were moved here one namespace at a time. This repository is also where the takeover of their live Helm releases was worked out: see [Taking over a legacy Helm release](#taking-over-a-legacy-helm-release).

## Layout

```
argocd/
  root-application.yaml          app-of-apps, applied by hand once on the hub
  kustomization.yaml             renders ONLY the five projects + the appset
  appsets/services.yaml          the one ApplicationSet (git files over apps/*/*/release.yaml)
  projects/<namespace>.yaml      hr, payments, access, i18n, ordering: destinations + developer role
  setup/                         one-time, unmanaged: repository registration, CSI credential shape
apps/<service>/{dev,services}/   release.yaml  image.yaml  values.yaml
bootstrap/
  populate-kv.sh                 seed one service's Key Vault objects (env vars, or a one-time legacy derivation)
  helm-only-fields.py            which fields only `helm` still owns on a live object
  strip-legacy-field-managers.sh hand the objects to argocd-controller after a takeover
```

| Namespace | Services | Chart(s) |
|---|---|---|
| `hr` | `hr-api`, `hr-portal`, `hr-admin`, `hr-absence`, `hr-employee-book` | `hr-api`; **`hr-app` shared by the four frontends** |
| `payments` | `payments-api`, `payments-invoicing`, `payments-email`, `payments-admin-web` | one chart each |
| `access` | `access-api`, `access-app` | one chart each |
| `i18n` | `i18n-api`, `i18n-app` | one chart each |
| `ordering` | `ordering-api` (NestJS), `ordering-app` (React/Vite) | dev only; see KNOWN-GAPS |

## How it works

The [ApplicationSet](argocd/appsets/services.yaml) uses a git files generator over `apps/*/*/release.yaml`. A service deploys to an env **if and only if** that file exists. Each generated Application `<service>-<env>` is multi-source:

1. the chart named by `release.yaml`'s **`chart.name`**, pulled from `orgacr.azurecr.io/helm` at **`chart.version`**, with `helm.releaseName` = the folder name;
2. this repository as `$values`, supplying `values.yaml` and then `image.yaml`, so the promoted digest wins.

Design points, each with a reason:

- **`chart.name` is explicit**, not derived from the folder. Several services can then share one chart: the four HR frontends are four Applications and four Helm releases of `hr-app`.
- **`helm.releaseName` = folder.** Four releases of one chart never collide. A takeover also keeps the object names the legacy `helm install` created.
- **The project is derived from the namespace**: `project: services-{{.destination.namespace}}`. This is **fail-closed**. A namespace without its own project file has no matching AppProject, so the controller skips the Application (`ErrorOccurred`). It never lands in `default` or in another team's project.
- **The destination emits both `server` and `name`, one of them empty.** Argo treats an empty string as unset, so dev resolves through `server` and services through `name`. The alternative, a YAML-level `{{if}}` around one key, would make the file invalid YAML for the root app's kustomize render, because templating happens only later in the ApplicationSet controller. And `missingkey=error` would reject a descriptor that omitted a key. So every descriptor carries both.
- **Every `services` descriptor names `aks-org-prod`**, the cluster that is actually registered. In the real repository half the services still named a cluster `services` that was never registered anywhere, so their Applications could not be generated, and the root app sat Degraded for a reason nobody looked at.

### The three descriptor files

| File | Who writes it | Role |
|---|---|---|
| `release.yaml` | `chart.version`: the CD promotion. `chart.name` and `destination`: a human, once. | **Presence = deploy switch**; pins chart and destination |
| `image.yaml` | the CD promotion ([`gitops-promote-steps.yml`](../../platform/ci-templates/steps/gitops-promote-steps.yml)) | `image.tag` + `image.digest` (the digest wins) |
| `values.yaml` | a human, in a reviewed PR | non-secret per-env overrides: routes, Key Vault name, `env:` configuration |

The CD ([`promote-stage.yml`](../../platform/ci-templates/stages/promote-stage.yml)) promotes in two steps. `Promote_Dev` writes `dev/` from the CI's `deploy-meta-<app>` artifact. `Promote_Services` is gated on the `Production` environment approval and copies the **exact** dev digest into `app/`. It never rebuilds. The promotion needs `release.yaml` to exist already (`requireReleaseFile: true`), because only a human decides where a service runs.

### Configuration and secrets

- **Non-secret configuration is `env:` in `values.yaml`**, rendered by the chart into a ConfigMap and reaching the pod as environment variables (`Section__Key` for .NET). Reloader restarts the pod when it changes. Each chart's `configmap.yaml` lists every key it accepts. Hostnames, realms, queue names and feature flags are therefore reviewable in a PR. Before, they were hidden inside a Base64 JSON blob in Key Vault.
- **SPA runtime configuration:** `env:` map → ConfigMap → `entrypoint.sh` writes `assets/config.json` before nginx starts → the app fetches it at boot. One image runs in every environment. The **base path is not runtime** (Angular `baseHref`, Vite `base`): moving a route without rebuilding the image 404s every asset.
- **Secrets:** one plain value per Key Vault object (`<app>--<object>`), mounted by the Secrets Store CSI driver. Seed them with [`bootstrap/populate-kv.sh`](bootstrap/populate-kv.sh) **before** the first promotion: the driver fails the whole mount on one missing object.

## Path allocation on `services.example.com`

One host and one TLS listener. Every app is a path prefix, rewritten to `/` (the same paths on `dev.example.com`).

| Path | App | Namespace |
|---|---|---|
| `/keycloak` | identity provider (platform layer) | `keycloak` |
| `/hr-api` | hr-api | `hr` |
| `/hr-portal`, `/hr-admin`, `/hr-absence`, `/hr-employee-book` | the four HR frontends | `hr` |
| `/payments-api` | payments-api | `payments` |
| `/payments-admin` | payments-admin-web | `payments` |
| `/access-api`, `/access-app` | access-api, access-app | `access` |
| `/i18n-api`, `/i18n-app` | i18n-api, i18n-app | `i18n` |
| `/ordering-api`, `/ordering` | ordering-api, ordering-app (dev only) | `ordering` |

`payments-invoicing` and `payments-email` are broker consumers with no route. Gateway listener hostnames match **exactly**, and every route sets `sectionName: websecure`. Without it, a route also binds the plain-HTTP listener.

## Taking over a legacy Helm release

A service that used to be deployed with `helm upgrade` is adopted in place. Its Application renders the same object names, release name and selector labels, so the first sync changes the objects without recreating them.

**The first sync does not finish the takeover.** Helm 4 deploys with server-side apply under the field manager `helm`. Argo (also server-side apply, `ServerSideApply=true`) never removes a field that another manager still owns. A field the old chart set and the new chart dropped therefore **stays on the live object**.

The incident: the old charts injected secrets as `env:` entries with `secretKeyRef`, and the new charts use `envFrom` on the CSI-synced Secret. After the first sync, the old `env` entries were still on the API Deployments, next to the new `envFrom`. Once the synced Secret no longer had those keys, every new pod failed with `CreateContainerConfigError`. The reverse also happens: a field the app still needs but the new chart never renders keeps working only by accident (a volume mount held by a leftover `helm` entry).

Once per namespace, after its Applications are Synced:

1. **See what only Helm still owns.** Anything the app still needs must go into the chart first, because the next step drops it:
   ```bash
   kubectl -n <ns> get deploy,svc,sa,hpa,httproute,secretproviderclass --show-managed-fields -o json \
     | python bootstrap/helm-only-fields.py
   ```
2. **Retire the Helm release records.** Delete the `sh.helm.release.v1.*` Secrets: the objects stay. Alternatively, `helm uninstall` and let auto-sync recreate everything; the service is then down for about a minute. A *Replace + Force* sync is not an option, because Force cannot be combined with `ServerSideApply=true`.
3. **Hand the objects to Argo:**
   ```bash
   bootstrap/strip-legacy-field-managers.sh <ns>            # dry run
   bootstrap/strip-legacy-field-managers.sh <ns> --apply
   ```
   This removes the `helm` and `kubectl-client-side-apply` entries from `managedFields`. Each removal is a JSON patch that `test`s the entry first, highest index first, so it is atomic and index-safe. The script refuses to run while Helm release records exist, because the next `helm upgrade` would re-add the manager. Argo's own client-side-apply migration does not help here: it converts only `Update` entries, and Helm 4 writes `Apply` entries.
4. Sync the affected Applications. A sync that already failed on those fields does not retry by itself for the same revision.

## Access model

Who sees and operates which Applications is decided here, per namespace. Each [`argocd/projects/<namespace>.yaml`](argocd/projects/payments.yaml) AppProject carries a `developer` role bound to one Keycloak group in realm `org-test`: `argocd-hr`, `argocd-payments`, `argocd-access`, `argocd-i18n`, `argocd-ordering`.

```
Keycloak (org-test)          this repo: argocd/projects/            hub Argo CD
  argocd-payments ──groups──> services-payments, role developer  ──> get, sync, actions, logs on its apps
  argocd-admins ────────────> argocd-rbac-cm: role:admin        ──> everything
  in no group ──────────────> policy.default: ""                 ──> an empty UI
```

- **`policy.default: ""`** in the hub's `argocd-rbac-cm` (platform layer): signing in grants nothing. Every permission comes from a project role or `argocd-admins`.
- The groups are created by IaC; **membership is set in Keycloak only, never in Git**. The `groups` claim must carry plain names (the group mapper's "full path" off). A leading `/` makes every project role stop matching.
- `developer` can get, sync, run resource actions (restart) and read logs. It cannot edit, delete, override or exec. Every Application has automated prune + selfHeal, so a UI edit would be reverted anyway; changes belong in Git.
- **One malformed policy line disables every policy of that project.** `argocd-server` logs "Failed to load casbin policies" and nothing validates the line on sync. Validate offline before merging:
  ```bash
  kubectl -n argocd-hub get cm argocd-rbac-cm -o yaml > rbac-cm.yaml
  argocd admin settings rbac validate --policy-file rbac-cm.yaml
  argocd admin settings rbac can proj:services-payments:developer sync applications 'services-payments/*' \
    --policy-file rbac-cm.yaml
  ```
  The project roles are not in `argocd-rbac-cm`, so check the derived lines too (`p, proj:<project>:developer, ...` and `g, <group>, proj:<project>:developer`).

**Moving to per-namespace projects without an outage.** The services first shared one project. The switch was two commits. The first added the five namespace projects and repointed the appset, **keeping the shared project in the kustomization**. The second, once every generated Application showed its new project, removed the shared one. Pruning it in the same sync as the appset switch would have raced the ApplicationSet controller's update of the Applications, and briefly orphaned them.

## Validate

```bash
kubectl kustomize argocd/ > /dev/null
bash -n bootstrap/*.sh && python -m py_compile bootstrap/helm-only-fields.py
# every release.yaml names chart.name, chart.version and both destination keys:
grep -L 'name: ""\|server: ""' apps/*/*/release.yaml    # must print nothing
```

## KNOWN-GAPS

- **Production Key Vault access uses the node (kubelet) identity.** It can read the **whole** `kv-org-prod`, for every pod on the node. The product side moved to one workload identity per app and env ([`gitops/apps`](../apps/README.md)); these services have not yet.
- **The dev hub uses a service-principal secret** (`secrets-store-creds`) for the CSI driver, because the on-prem hub has no node identity. Workload identity through the hub's published OIDC issuer would remove it.
- **Ordering is not promoted to production.** `ordering-api` needs MongoDB, and `aks-org-prod` provides none (no in-cluster database, no managed API-compatible account in IaC). Its `app/` folders hold values only, without a `release.yaml`, so nothing is generated, and a promotion fails loudly until the decision is made.
- **`aks-org-prod` is a single node** shared with the platform layer. Autoscaling is off and every service runs one replica.
- **No ordering between Applications.** Schema changes run inside each service's own deploy; Argo does not order one Application after another.
