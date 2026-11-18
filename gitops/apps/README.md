# gitops/apps (the `product-a-gitops` repository)

The GitOps source of truth for Product A's pull-based environments: **stage, demo and prod**. Argo CD reconciles them. Dev stays push-based (the service's CD pipeline runs `helm upgrade`), so `apps/<svc>/dev/` is only the record of the validated candidate that promotions copy.

In the real repository about 18 services ran this model. This folder keeps five that cover every pattern: a .NET API, a Python FastAPI module, an Angular SPA, a migration Job chart, and a CronJob chart.

## Two Argo CDs, two render targets

| Target | Reconciled by | Destination | Render target | Root app |
|---|---|---|---|---|
| stage, demo | the **hub** Argo CD (`hub-dev`, ns `argocd-hub`) | registered spokes `product-a-stage` (MicroK8s) and `aks-product-a-demo` | [`argocd/`](argocd/kustomization.yaml) | declared in `gitops/platform` |
| **prod** | the Argo CD **on `aks-product-a-prod`** (ns `argocd`) | in-cluster, ns `product-a` | [`argocd/overlays/prod/`](argocd/overlays/prod/kustomization.yaml) | [`argocd/root-application-prod.yaml`](argocd/root-application-prod.yaml), applied once by hand |

Prod is an island, not a hub spoke. Its own Argo CD already serves the platform layer on that cluster, so it reconciles the application layer too. There is no cluster Secret to register. The two render targets are **disjoint on purpose**. Applying either root on the other's cluster would generate Applications for a cluster that Argo has never heard of.

## The approval is the deployment

Every deployment decision is made in Azure DevOps. Each promotion is an approval-gated stage of the service's CI pipeline ([`platform/ci-templates/stages/build-or-promote-stage.yml`](../../platform/ci-templates/stages/build-or-promote-stage.yml)) bound to an Environment: `Stage`, `Demo` or `Production`. Approving the check **is** the deployment. The stage writes the promoted image digest and an exact chart pin here in one commit, and Argo reconciles to exactly that. Argo is only the executor: it can only ever deploy what an approval wrote.

```
develop build   -> az acr build once        -> record apps/<svc>/dev/image.yaml (digest + version)
main merge      -> push chart x.y.z (no build), then wait for approvals:
  approve Stage       -> apps/<svc>/stage/{image,release}.yaml -> Argo syncs stage
  approve Demo        -> apps/<svc>/demo/{image,release}.yaml  -> Argo syncs demo
  approve Production  -> copy the exact stage pair to prod/    -> sync prod (manual until re-armed)
```

Rollback is `git revert` of the promotion commit, or a re-run with `allowDowngrade`. The promotion refuses to write an older pin than the one running unless that is set, so approving a stale run cannot roll an environment back by accident.

## The file model: who writes which file

A service runs in an environment **if and only if** `apps/<svc>/<env>/release.yaml` exists. The ApplicationSet's git-files generator turns each such file into an Application.

| File | Written by | Holds | Read by |
|---|---|---|---|
| `apps/<svc>/dev/image.yaml` | CI on `develop` ([`gitops-record-steps.yml`](../../platform/ci-templates/steps/gitops-record-steps.yml)) | `image.digest`, `image.version` of the dev candidate | the Promote stages only (Argo never reads dev) |
| `apps/<svc>/<env>/image.yaml` | the approval-gated promotion | the digest + version copied from dev (stage, demo) or stage (prod) | Argo: second value file, so it wins |
| `apps/<svc>/<env>/release.yaml` | `.chart.version`: the promotion. Any other key: a human. | the exact chart pin, optional `syncPolicy` opt-out | the ApplicationSet generator |
| `apps/<svc>/<env>/values.yaml` | a human, in a reviewed PR | the whole per-env configuration, non-secret | Argo: first value file |

The promotion edits `release.yaml` with `yq` and sets only `.chart.version`. Hand-maintained keys survive, such as [`product-a-db`'s `selfHeal: false`](apps/product-a-db/stage/release.yaml). The first version rewrote the whole file, which would have silently put the migration Job back under selfHeal on the next promotion.

## Layout

```
apps/<svc>/
  dev/image.yaml                          record only
  {stage,demo,prod}/{release,image,values}.yaml
argocd/
  kustomization.yaml                      HUB render target: projects + stage/demo appsets
  projects/product-a-{stage,demo}.yaml    one AppProject per env, developer role -> Keycloak group
  appsets/product-a-{stage,demo}.yaml     git-files generator, multi-source, templatePatch
  overlays/prod/                          PROD render target: scoped project + appset (manual sync)
  root-application-prod.yaml              applied once on the prod cluster
  setup/ setup.sh .env.example            one-time credentials (never in a render target)
scripts/check-configmaps.py               the values completeness / drift / perturbation check
scripts/configmap-exceptions.yaml         every exception with its reason
azure-pipelines-lint.yml                  runs the check on every PR touching apps/ or scripts/
```

| App | What it is | Notes |
|---|---|---|
| [`product-a-api`](apps/product-a-api/) | .NET API | HPA on in prod, two replicas with anti-affinity |
| [`product-a-module`](apps/product-a-module/) | Python FastAPI | `promptGovernance.enabled` makes a Key Vault object mandatory |
| [`product-a-web`](apps/product-a-web/) | Angular SPA | runtime `env.js`, no secrets, no identity |
| [`product-a-db`](apps/product-a-db/) | migration Job chart, same image as the API | `selfHeal: false`, pin-paired with the API |
| [`product-a-referencedata`](apps/product-a-referencedata/) | CronJobs + seed Jobs | explicit per-dataset keys, `cronDefaults` |

## Key techniques

| Technique | Where |
|---|---|
| Multi-source Application: OCI chart at `{{.chart.version}}` + this repo as `$values`; value files `values.yaml` then `image.yaml` | [appsets/product-a-stage.yaml](argocd/appsets/product-a-stage.yaml) |
| Reloader `ignoreDifferences` on every kind it restarts, with `RespectIgnoreDifferences=true` (load-bearing: without it a sync strips the annotation and restarts the pods anyway) | same |
| `templatePatch` + `dig` for per-app boolean overrides. The CRD types `prune`/`selfHeal` as booleans, so a templated string in `template:` is rejected by the API server | same |
| Prod: manual sync with a **per-app structural opt-in**: `index . "syncPolicy"` (safe under `missingkey=error`) and a `{}` no-op patch for every app that does not opt in | [appset-product-a-prod.yaml](argocd/overlays/prod/appset-product-a-prod.yaml) |
| Prod `retry` with backoff: charts are pulled over the network on every sync | same |
| One AppProject per environment, `developer` role bound to a Keycloak group. One malformed policy line disables **every** policy of the project | [projects/product-a-stage.yaml](argocd/projects/product-a-stage.yaml) |
| Credentials never in a render target, so a prune cannot delete the credential needed to read the repository; `forceHttpBasicAuth` because Azure DevOps answers with a 302, not a 401 | [setup/](argocd/setup/README.md) |
| Workload identity per app and env for Key Vault (client id per env), replacing the shared kubelet identity | any `values.yaml`, e.g. [api/prod](apps/product-a-api/prod/values.yaml) |
| ConfigMap **perturbation** check: every leaf of `config` is altered and the chart re-rendered; a key that does not move is chart-owned | [check-configmaps.py](scripts/check-configmaps.py) |
| Pin-pair consistency: API and migration chart must share chart version and digest in every env | same + [configmap-exceptions.yaml](scripts/configmap-exceptions.yaml) |

## Values conventions

- **Every per-env decision is stated.** `replicaCount`, `autoscaling`, `resources`, the three probes, `nodeSelector`, `tolerations`, `affinity`, `workloadIdentity`, `otel`, `config` (plus `migrationJob`, `cronDefaults` and `seedOnDeploy` where the chart has them) appear in every env file, even when the value equals the chart default. A chart-default change can then never move an environment silently. `OWNED_KEYS` in the check enforces this.
- **Silence is not a decision.** An unguarded template key renders the chart default when omitted. A guarded key (`{{- with }}`) renders no variable, and the application's built-in DEV default wins. Both happened: one environment logged as "Production" because `ENVIRONMENT` was empty, and another fetched machine-to-machine tokens from the dev identity provider because its token URL was missing. A key that must be absent in one env is a comment plus an `allowEnvOnly` entry with a reason.
- **Readable config.** Values are plain text or JSON. If a binder needs Base64, the chart encodes at render time. Check 3 rejects Base64-encoded JSON in a ConfigMap.
- **A config flag can make a secret mandatory.** `config.promptGovernance.enabled: true` (module) or `config.blobStorage.enabled: true` (api) adds a Key Vault object to the SecretProviderClass. The CSI driver fails the **whole** mount if one object is missing, and the pod sits in `ContainerCreating` while Argo shows Synced. Seed the object before you flip the flag.
- **Gateway `sectionName: websecure`.** It pins the HTTPRoute to the TLS listener. Without it the route also binds the plain-HTTP listener. Listener hostnames match exactly: a route on another host reports `NoMatchingParent` while Argo stays Healthy.
- **Comment blocks.** Each file starts with the same header (env, cluster, where secrets come from, where the digest comes from) and groups keys under the same section rules. A reviewer reads every env file the same way.

### Values contract (what the charts in [`app/`](../../app/) read)

`replicaCount`, `image.{repository,tag,digest,pullPolicy}` (the digest wins), `imagePullSecrets`, `workloadIdentity.{enabled,clientId}` (service account annotation + SecretProviderClass `clientID`), `azureKeyVault.{enabled,keyvaultName,tenantId}`, `gateway.{enabled,name,namespace,sectionName}`, `route.{enabled,hostnames,path,rewrite.{enabled,replacePrefixMatch}}`, `resources`, `autoscaling.{enabled,minReplicas,maxReplicas,targetCPUUtilizationPercentage}`, `{startup,readiness,liveness}Probe.{enabled,path,periodSeconds,failureThreshold}`, `nodeSelector`, `tolerations`, `affinity`, `otel.{enabled,endpoint}`, `config.*`; Job chart: `migrationJob.{enabled,mode,runNonce,activeDeadlineSeconds,backoffLimit,resources}`; CronJob chart: `cronDefaults.*`, `seedOnDeploy.enabled`, `datasets.<name>.{enabled,schedule}`.

## Chart versioning

Charts are versioned **per build**. CI stamps `version` and `appVersion` with `helm package --version --app-version`: `x.y.z-alpha.n` on develop, `x.y.z` on main. Pushing a chart deploys nothing. Each env pins an **exact** version in `release.yaml`, and only a promotion moves that pin, together with the digest, in one commit.

> **Never pin `chart.version: "*"`.** `*` is a SemVer range, and ranges exclude prereleases. If every tag of a chart is a prerelease, `*` resolves to nothing and Argo fails with "version matching constraint not found". The promotion step refuses `*` outright.

## Access

On the hub, each environment is its own AppProject with a `developer` role bound to one Keycloak group in realm `org-test`: `product-a-stage` with `argocd-product-a-stage`, and `product-a-demo` with `argocd-product-a-demo`. Members can get, sync, run resource actions (restart) and read logs on that environment's Applications, and nothing else. There is no edit or delete on purpose: selfHeal would revert a UI edit anyway, so changes belong in Git. Membership is managed in Keycloak, never in Git.

**One malformed policy line disables every policy of its project.** `argocd-server` logs "Failed to load casbin policies", and nothing validates the line on sync. Check a change offline before you merge it (`argocd admin settings rbac validate`, then `argocd admin settings rbac can <role> sync applications 'product-a-stage/*'`).

## Bootstrap gates

| # | Gate | Hub (stage/demo) | Prod |
|---|---|---|---|
| 1 | ADO Environments `Stage`, `Demo`, `Production` with approval checks | [`set-environment-approvals.sh`](../../platform/ci-templates/scripts/ado/set-environment-approvals.sh) | same |
| 2 | Build identity has Contribute on this repository | once | same |
| 3 | Repository credentials (git + OCI), outside any render target | [`setup.sh`](argocd/setup.sh) | [`setup/prod`](argocd/setup/prod/README.md) |
| 4 | Spokes registered (`product-a-stage`, `aks-product-a-demo`) | `setup.sh` | none (in-cluster) |
| 5 | Root app | declared in `gitops/platform` | `root-application-prod.yaml`, once |
| 6 | Federated identity per app/env with Key Vault Secrets User | IaC (stage via the published OIDC issuer) | IaC |
| 7 | Every Key Vault object a chart declares is seeded | before the first promotion | before the first sync |
| 8 | First promotion | approval writes `release.yaml`; the Application appears | approval, then a manual `argocd app sync` (Job chart first) |

## Go-live lessons (prod)

- **Prod values were copied from a broken stage.** The first prod files were copies of the stage files. Stage is an on-prem MicroK8s cluster, so prod arrived pointing at endpoints that do not exist on `aks-product-a-prod`: an on-prem service address the prod network has no route to, a storage emulator on a ClusterIP, a stage-only realm, and a namespace name the RBAC chart never grants. All of them were **re-homed** onto what the prod platform layer actually provides, not patched one error at a time. The values are now written per environment, and the `<env>` folder names the cluster in its header.
- **`route.tls` was inert.** Every prod route named a TLS secret, and the chart never read `route.tls`. TLS terminates on the Gateway's `websecure` listener. The block looked like configuration and guaranteed nothing, so it was removed with a comment that says why.
- **Concurrent pushes lost records.** Every service writes into this one branch. Two pipelines finishing within seconds raced, and the loser failed with `TF401028`. The image **had** been built and pushed; only its record was lost, so the next deploy silently shipped the previous image. Both GitOps step templates now fetch, rebase and retry up to five times. Each build only touches its own `apps/<svc>/` folder, so the rebase is conflict-free by construction, and a real conflict still fails loudly.
- **A chart rename left two environments on an old image for weeks.** The promotion wrote a pin for the new chart name. With no `values.yaml` in that folder the Application could not render, and the old one kept running while the pipeline reported success. The promotion now refuses when `<env>/values.yaml` is missing.

## Validate

```bash
python -m py_compile scripts/check-configmaps.py
python scripts/check-configmaps.py --offline              # pin pairs; renders whatever is cached
python scripts/check-configmaps.py --charts-dir <dir>     # <dir>/<app>/Chart.yaml: working-tree charts
kubectl kustomize argocd/ > /dev/null && kubectl kustomize argocd/overlays/prod > /dev/null
```

## KNOWN-GAPS

- **Prod sync is still manual** (by decision, until launch confidence). No selfHeal, so drift is not corrected in prod. Re-arming is one commit, the `{{- else }}` branch of the prod `templatePatch`.
- **No ordering between the migration Application and the API Application** in GitOps environments. Argo gives none across Applications; migrations must be expand/contract compatible. Dev keeps an explicit order in its pipeline.
- **The prod Argo CD has no developer role yet.** Only the hub projects carry Keycloak-bound roles.
- **The hub repository credential is still a token.** `gitops/services` already inherits a workload-identity repo-creds template; this repository should follow.
- **PodDisruptionBudget and topologySpreadConstraints** are not values yet (the charts lack templates). They matter as soon as a service runs more than one replica.
- **`metrics-server` was missing on stage**, so an HPA there would not scale. HPA is enabled only in prod.
- **Stage/demo promote the dev image at approval time** paired with the main run's chart (see [`platform/ci-templates` KNOWN-GAPS](../../platform/ci-templates/README.md#known-gaps)).
