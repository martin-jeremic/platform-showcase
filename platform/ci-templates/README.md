# platform/ci-templates (the `shared-templates` repository)

Azure Pipelines templates shared by every service pipeline in the organisation. The real repository started as two copies: one inside the product-a monorepo (`platform/ci-templates/`) and one in a shared `shared-templates` repository that the company services consumed. This folder merges them into one versioned template repository and fixes the shortcuts both copies had.

It implements two delivery variants of one idea: **build an image once, identify it by digest, and deploy by writing that digest into Git behind an approval.** Argo CD only reconciles.

| Variant | Who | Build | Promote | GitOps repo |
|---|---|---|---|---|
| Product (A) | product-a services | `develop` builds with `az acr build` and records the digest in `apps/<app>/dev/` | `main` pushes the chart, then `Promote_Stage` / `Promote_Demo` / `Promote_Prod` wait for approvals | [`gitops/apps`](../../gitops/apps/) |
| Company (B) | payments, hr, access, i18n, ordering | `main` builds once and publishes a `deploy-meta-<app>` artifact | a separate CD pipeline: `Promote_Dev` from the artifact, `Promote_Services` approval-gated from GitOps | [`gitops/services`](../../gitops/services/) |

## Consuming the templates

Templates are consumed **by tag**. A change to a template can then never alter a running service's pipeline until that service moves its `ref`:

```yaml
resources:
  repositories:
    - repository: templates
      type: git
      name: platform/shared-templates
      ref: refs/tags/v1          # pinned by tag, not main
    - repository: gitops         # only for pipelines that record or promote
      type: git
      name: product-a/product-a-gitops

stages:
  - template: stages/versioning-gitversion.yml@templates
    parameters:
      gitVersionConfig: src/api/GitVersion.yml
  - template: stages/convention-checks-stage.yml@templates
  - template: stages/build-or-promote-stage.yml@templates
    parameters:
      imageName: product-a-api
      helmChartPath: src/api/charts/product-a-api
      dockerfilePath: src/api/Dockerfile
      secondHelmChartPath: src/api/charts/product-a-db
      secondImageName: product-a-db
```

Company CI and CD:

```yaml
# CI.yml (trigger: main)
stages:
  - template: stages/versioning-semantic-release.yml@templates
  - template: stages/build-stage.yml@templates
    parameters:
      images:
        - { name: hr-portal, dockerfile: Dockerfile, buildContext: ., buildArgs: { APP_NAME: portal } }
        - { name: hr-admin,  dockerfile: Dockerfile, buildContext: ., buildArgs: { APP_NAME: admin } }
      chartName: hr-app
      chartDir: charts/hr-app
      npmrcSecureFile: npmrc-private-feed
      validateAgainstGitops: true

# CD.yml (trigger: none; resources.pipelines: - pipeline: ci, source: hr-app-ci)
stages:
  - template: stages/promote-stage.yml@templates
    parameters:
      apps: [hr-portal, hr-admin]
      metaPipelineAlias: ci
```

## Layout

```
stages/
  versioning-gitversion.yml        GitVersion (Mainline, commit-message bumps, develop = alpha)
  versioning-semantic-release.yml  semantic-release dry run, isReleaseReady gating
  convention-checks-stage.yml      merge-conflict markers, required files, pinned gitleaks (blocking)
  build-or-promote-stage.yml       variant A: build/scan/record on develop, approval-gated promotion on main
  build-stage.yml                  variant B: build once per image, deploy-meta artifact, chart push
  promote-stage.yml                variant B: Promote_Dev (artifact) + Promote_Services (gitops, approval)
  pr-dotnet-stage.yml              locked restore, build, named suites, EF pending-model guard, coverage
  pr-python-stage.yml              venv, flake8, pytest (JUnit + Cobertura), dummy settings
  pr-node-stage.yml                lint through a Dockerfile target, optional npm scripts
  pr-helm-stage.yml                lint + template per values file, no `{{ range }}`
  refuse-placeholders-stage.yml    fail a deploy while any <<NAME>> marker remains
  migration-deploy-stage.yml       push-based: migration Job chart, by digest, --wait-for-jobs
  deploy-environment-stage.yml     push-based: app chart, by digest
  config-deploy-stage.yml          values-only redeploy, chart + image read back from the release
steps/
  gitops-record-steps.yml          resolve + validate digest, record it with a fetch/rebase/retry push
  gitops-promote-steps.yml         write image.yaml + chart pin after approval, with guards
  yq-install-steps.yml             pinned, checksum-verified yq (used by the two above)
  trivy-install-steps.yml          pinned, checksum-verified Trivy
  trivy-scan-steps.yml             image or filesystem scan, warn-only, findings in the Tests tab
  hadolint-steps.yml               Dockerfile lint, warn-only
scripts/ado/                       idempotent az devops bootstrap: pipelines, policies, approvals, cleanup
examples/                          nightly E2E pipeline, GitVersion and semantic-release configs, licence gate shape
```

## Key techniques

| Technique | Where |
|---|---|
| Build, scan and digest lookup are **separate `AzureCLI@2` tasks**: the federated client assertion lives 10 minutes, and a build that crossed ~9 minutes lost its digest record | [build-or-promote-stage.yml](stages/build-or-promote-stage.yml), [build-stage.yml](stages/build-stage.yml) |
| `az acr build`: no Docker daemon on the agents, the image never exists on the agent, no `:latest` tag | [build-or-promote-stage.yml](stages/build-or-promote-stage.yml) |
| `fetchDepth: 0` in every CI job, because one shallow job leaves the shared work folder shallow for GitVersion | [build-or-promote-stage.yml](stages/build-or-promote-stage.yml), [convention-checks-stage.yml](stages/convention-checks-stage.yml) |
| `uses: repositories: [gitops]`: with "Protect access to repositories" on, the job token only covers repositories the job declares | [build-or-promote-stage.yml](stages/build-or-promote-stage.yml), [promote-stage.yml](stages/promote-stage.yml) |
| A companion chart packaged with the **same version** in the same job, and recorded/promoted with the same digest in the same commit | [build-or-promote-stage.yml](stages/build-or-promote-stage.yml), [gitops-record-steps.yml](steps/gitops-record-steps.yml) |
| Digest validated against `^sha256:[0-9a-f]{64}$` before anything is written | [gitops-record-steps.yml](steps/gitops-record-steps.yml), [gitops-promote-steps.yml](steps/gitops-promote-steps.yml) |
| Push with a **fetch / rebase / retry** loop (5 attempts): many pipelines write one branch | both GitOps step templates |
| Clone **after** the approval, at the current tip, with the token as a per-command bearer header (never in `.git/config`), and a `trap` that removes the clone | [gitops-promote-steps.yml](steps/gitops-promote-steps.yml) |
| `yq` edits: only `.chart.version` is written, so hand-maintained keys of `release.yaml` survive | [gitops-promote-steps.yml](steps/gitops-promote-steps.yml) |
| **Promotion ordering guard**: refuse a chart pin older than the target's current one unless `allowDowngrade` (a SemVer 2.0 comparator, because `sort -V` orders prereleases wrongly) | [gitops-promote-steps.yml](steps/gitops-promote-steps.yml) |
| Refuse a promotion when `<env>/values.yaml` is missing | [gitops-promote-steps.yml](steps/gitops-promote-steps.yml) |
| `deploy-meta` artifact parsed, never `source`d | [gitops-promote-steps.yml](steps/gitops-promote-steps.yml) |
| semantic-release dry run + `isReleaseReady` gate: a `chore:` commit publishes nothing | [versioning-semantic-release.yml](stages/versioning-semantic-release.yml), [build-stage.yml](stages/build-stage.yml) |
| Trivy warn-only with summary, run tag, JUnit "one failed test per finding"; `awk` counting instead of `grep \| wc -l` under `pipefail` | [trivy-scan-steps.yml](steps/trivy-scan-steps.yml) |
| gitleaks pinned, `--no-git`, **fails closed** (scanners that warn vs gates that block) | [convention-checks-stage.yml](stages/convention-checks-stage.yml) |
| No `{{ range }}` in chart templates (a blanket `if $v` once dropped every false flag) | [pr-helm-stage.yml](stages/pr-helm-stage.yml) |
| EF Core `has-pending-model-changes` guard; `--locked-mode` restore | [pr-dotnet-stage.yml](stages/pr-dotnet-stage.yml) |
| BuildKit `--secret id=npmrc` for a private feed (the source wrote a token into a layer) | [build-stage.yml](stages/build-stage.yml), [pr-node-stage.yml](stages/pr-node-stage.yml) |
| `--wait --wait-for-jobs` (Helm 4 otherwise reports a failing Job as deployed), digest required, Job logs and events printed on failure | [migration-deploy-stage.yml](stages/migration-deploy-stage.yml) |
| Config-only deploy without `--reuse-values`: chart version and image read back from the release | [config-deploy-stage.yml](stages/config-deploy-stage.yml) |
| Branch policies whose path filters mirror `PR.yml`, because the YAML `pr:` block is ignored for Azure Repos | [set-branch-policies.sh](scripts/ado/set-branch-policies.sh) |
| Environment approval check through the REST API: fixed check-type GUID, approvers from a variable or arguments, self-approval off, timeout | [set-environment-approvals.sh](scripts/ado/set-environment-approvals.sh) |
| Nightly pipeline: `always: true`, secrets mapped through `env:`, and the warning that a UI schedule overrides the YAML | [e2e-nightly.yml](examples/e2e-nightly.yml) |

### Conventions applied everywhere

- **No user-controlled text is spliced into a script.** Parameters and variables reach bash through `env:`, and build arguments are assembled into a bash array from environment variables. `${{ parameters.x }}` appears only in YAML positions such as `displayName`, `condition` and `inputs`.
- **Branch-specific work is gated by `condition:`** on the step or stage, never by `exit 0` inside a script. The run view then shows the step as skipped, not as a green step that did nothing.
- **Charts are versioned by `helm package --version --app-version`**, never by `sed` on `Chart.yaml`. The working tree stays clean.
- **No `:latest` tags.** Every environment reads a digest.
- **Temporary clones are removed by a `trap`.**
- **Pinned tool versions** (Helm, yq, Trivy, hadolint, gitleaks, GitVersion, semantic-release), each verified by checksum where the release publishes one.

## Parameter reference

This is the contract the service pipelines in [`app/`](../../app/) rely on. Defaults in *italics* are organisation-specific.

### Versioning (both templates expose the same outputs)

Outputs: `Versioning.SemanticVersioning.DetermineVersion.{nextVersion,isReleaseReady}`. Read them as `$[ stageDependencies.Versioning.SemanticVersioning.outputs['DetermineVersion.nextVersion'] ]` and `dependencies.Versioning.outputs['SemanticVersioning.DetermineVersion.isReleaseReady']`. Both templates also name the run after the version, so a CD can read it as `resources.pipeline.<alias>.runName`.

**stages/versioning-gitversion.yml**

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `gitVersionConfig` | string | `GitVersion.yml` | Path to the GitVersion config (per service in a monorepo) |
| `gitVersionSpec` | string | `6.3.x` | GitVersion tool version |
| `releaseBranch` | string | `refs/heads/main` | Branch on which `isReleaseReady` can be true |
| `createTag` | boolean | `true` | Tag the release commit |
| `dependsOn` | object | `[]` | |
| `pool` | object | `{name: Default}` | |

**stages/versioning-semantic-release.yml**

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `releaseBranch` | string | `refs/heads/main` | |
| `nodeVersion` | string | `20.x` | |
| `semanticReleaseVersion` | string | `24.2.3` | Pinned semantic-release |
| `extraPlugins` | object | changelog 6.0.3, git 10.0.1 | Pinned plugin specs |
| `workingDirectory` | string | `$(Build.SourcesDirectory)` | Where `.releaserc` lives |
| `dependsOn` | object | `[]` | |
| `pool` | object | `{name: Default}` | |

### stages/convention-checks-stage.yml

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `stageName` | string | `ConventionChecks` | |
| `dependsOn` | object | `[]` | |
| `gitleaksVersion` | string | `8.30.1` | Pinned; checksum verified; fails closed |
| `requiredFiles` | object | `[]` | Paths that must exist |
| `fetchDepth` | number | `0` | Keep 0 in pipelines that run GitVersion |
| `pool` | object | `{name: Default}` | |

### stages/build-or-promote-stage.yml (variant A)

Produces the stages `<stageName>`, `Promote_Stage`, `Promote_Demo`, `Promote_Prod`. The caller must declare `resources.repositories: gitops` and a `Versioning` stage.

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `stageName` | string | `BuildOrPromote` | |
| `dependsOn` | object | `[Versioning]` | Must include `Versioning` |
| `imageName` | string | required | Image repo = OCI chart name = GitOps app folder |
| `helmChartPath` | string | required | |
| `dockerfilePath` | string | required | |
| `buildContext` | string | `.` | |
| `secondHelmChartPath` | string | `''` | Companion chart, same version |
| `secondImageName` | string | `''` | Companion GitOps folder; same digest, same commit |
| `buildArgs` | object | `{}` | `{NAME: value}`; `VERSION`, `REVISION`, `SOURCE` are always passed |
| `secretBuildArgs` | object | `{}` | `{NAME: $(secret)}` via `--secret-build-arg`; consume in a builder stage only |
| `preBuildSteps` | stepList | `[]` | Run on the build branch only (their own `condition` is replaced) |
| `scanImage` | boolean | `true` | Trivy, warn-only |
| `acrName` | string | *`productacr`* | |
| `armServiceConnection` | string | *`arm-product-a`* | |
| `gitopsRepoUrl` | string | *`https://dev.azure.com/example-org/product-a/_git/product-a-gitops`* | |
| `gitopsBranch` | string | `main` | |
| `buildBranch` | string | `refs/heads/develop` | |
| `releaseBranch` | string | `refs/heads/main` | |
| `stageEnvironmentName` / `demoEnvironmentName` / `prodEnvironmentName` | string | `Stage` / `Demo` / `Production` | ADO Environments carrying the approvals |
| `allowDowngrade` | boolean | `false` | Passed to every promotion |
| `helmVersion` | string | `4.2.0` | |
| `pool` | object | `{name: Default}` | |

### stages/build-stage.yml (variant B)

Produces the stage `BuildAndPush`, gated on `isReleaseReady` by default. For every image it publishes the artifact `deploy-meta-<name>`, which holds `image.env` with `VERSION=` and `DIGEST=`.

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `images` | object | required | `[{name, dockerfile, buildContext?, buildArgs?}]` |
| `chartName` | string | required | OCI chart name (may be shared, e.g. `hr-app`) |
| `chartDir` | string | required | |
| `acrName` | string | *`orgacr`* | |
| `armServiceConnection` | string | *`arm-platform`* | |
| `npmrcSecureFile` | string | `''` | Secure file mounted as BuildKit secret `npmrc` |
| `requireReleaseReady` | boolean | `true` | |
| `validateAgainstGitops` | boolean | `false` | Render the chart with every `apps/<image>/<env>` before pushing (needs `resources.repositories: gitops`) |
| `gitopsRepoUrl` | string | *`https://dev.azure.com/example-org/platform/_git/services-gitops`* | |
| `gitopsEnvs` | object | `[dev, services]` | |
| `helmVersion` | string | `4.2.0` | |
| `dependsOn` | object | `[Versioning]` | |
| `pool` | object | `{name: Default}` | Needs a Docker daemon |

### stages/promote-stage.yml (variant B)

Produces the stages `Promote_Dev` and `Promote_Services`. The caller declares `resources.pipelines` (the CI) and `resources.repositories: gitops`.

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `apps` | object | required | App folders; each needs a `deploy-meta-<app>` artifact |
| `metaPipelineAlias` | string | required | Alias of the CI pipeline resource |
| `gitopsRepoUrl` | string | *gitops/services URL* | |
| `gitopsBranch` | string | `main` | |
| `devEnv` / `servicesEnv` | string | `dev` / `services` | GitOps env folders |
| `devEnvironmentName` / `servicesEnvironmentName` | string | `Development` / `Production` | ADO Environments; only `Production` has an approval |
| `allowDowngrade` | boolean | `false` | |
| `pool` | object | `{name: Default}` | |

### PR stages

**stages/pr-dotnet-stage.yml**: `stageName` (`Build`), `dependsOn` (`[]`), `solution` (required), `suites` (`[]`, test project paths), `testFilter` (`''`), `efGuards` (`[]`, `[{project, startupProject?, context}]`), `collectCoverage` (`true`), `buildConfiguration` (`Release`), `dockerfile` (`''`; adds hadolint + a Trivy fs scan), `pool`.

**stages/pr-python-stage.yml**: `stageName` (`Test`), `dependsOn`, `projectRoot` (required), `requirementsFile` (`requirements.txt`), `extraPackages` (`[]`), `testPath` (`tests`), `pythonVersion` (`3.12`), `flake8Args` (`--max-line-length=120`), `testEnv` (`{LLM_API_KEY: ci-dummy-not-a-real-key}`), `dockerfile` (`''`), `pool`.

**stages/pr-node-stage.yml**: `stageName` (`NodeChecks`), `dependsOn`, `dockerfile` (required), `buildContext` (`.`), `lintTarget` (`lint`), `npmrcSecureFile` (`''`), `npmScripts` (`[]`), `workingDirectory` (`.`), `nodeVersion` (`20.x`), `pool`.

**stages/pr-helm-stage.yml**: `stageName` (`HelmValidate`), `dependsOn`, `charts` (required, chart directories), `namespace` (`pr-validation`), `forbidRange` (`true`), `helmVersion` (`4.2.0`), `pool`.

### Deploy stages (push-based dev)

**stages/refuse-placeholders-stage.yml**: `stageName` (`RefusePlaceholders`), `dependsOn` (`[]`), `valuesFiles` (required), `pool`.

**stages/migration-deploy-stage.yml**

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `stageName` | string | `Migrate_Dev` | |
| `dependsOn` / `condition` | object / string | `[]` / `succeeded()` | |
| `environmentName` | string | `Development` | |
| `namespace` | string | required | |
| `chartName` | string | required | The Job chart, e.g. `product-a-db` |
| `releaseName` | string | `''` (= chartName) | |
| `imageName` | string | required | The image the Job runs (the API image) |
| `version` | string | required | Chart version = image tag, e.g. `$(resources.pipeline.ci.runName)` |
| `valuesFile` | string | `''` | |
| `runMigrations` | boolean | `true` | Untick for one run to deploy past a failing migration |
| `helmTimeout` | string | `25m` | Sized for the Job's `activeDeadlineSeconds` |
| `acrName` / `armServiceConnection` | string | *`productacr`* / *`arm-product-a`* | |
| `helmVersion` | string | `4.2.0` | |
| `pool` | object | `{name: Default, demands: [dev-deploy]}` | Agent with a kubeconfig for dev |

Chart contract: `image.repository`, `image.digest`, `migrationJob.enabled`, `migrationJob.runNonce`. The Job is labelled `example.com/job-kind=schema-migration` and annotated `example.com/run-nonce`.

**stages/deploy-environment-stage.yml**: `stageName` (`Deploy_Dev`), `dependsOn`, `condition` (`succeeded()`), `environmentName` (`Development`), `namespace`, `chartName`, `releaseName` (`''`), `imageName`, `version` (all required except where a default is shown), `valuesFile` (`''`), `helmTimeout` (`10m`), `acrName`, `armServiceConnection`, `helmVersion`, `pool`. Sets `image.repository`, `image.tag` and `image.digest`; the digest is required.

**stages/config-deploy-stage.yml**: `environmentName` (`Development`), `namespace`, `chartName`, `releaseName` (`''`), `valuesFile` (required), `helmTimeout` (`10m`), `acrName`, `armServiceConnection`, `helmVersion`, `pool`. Produces `RefusePlaceholders` and `ConfigDeploy`.

### Step templates

**steps/gitops-record-steps.yml**: `imageName`, `pairedImageName` (`''`), `version`, `acrName`, `armServiceConnection`, `gitopsRepoUrl`, `gitopsBranch` (`main`), `targetEnv` (`dev`), `condition` (`succeeded()`). Writes `image: {digest, version}`.

**steps/gitops-promote-steps.yml**

| Parameter | Type | Default | Meaning |
|---|---|---|---|
| `appName` | string | required | |
| `pairedAppName` | string | `''` | Promoted in the same commit |
| `targetEnv` | string | required | |
| `sourceEnv` | string | `''` | gitops mode |
| `digestFrom` | `gitops` \| `artifact` | `gitops` | |
| `metaPipelineAlias` | string | `''` | artifact mode |
| `metaArtifactName` | string | `deploy-meta-<appName>` | artifact mode |
| `chartVersion` | string | `''` | `''` = source env's pin (gitops) or `VERSION` (artifact) |
| `allowDowngrade` | boolean | `false` | |
| `requireReleaseFile` | boolean | `false` | `true` when `release.yaml` carries a hand-seeded destination |
| `gitopsRepoUrl` | string | required | |
| `gitopsBranch` | string | `main` | |

**steps/trivy-scan-steps.yml**: `scanType` (`image` \| `fs`), `imageName`, `version`, `acrName`, `armServiceConnection` (image mode), `scanPath` (`.`, fs mode), `reportName` (required), `condition`.

**steps/trivy-install-steps.yml**: `trivyVersion` (`0.76.1`), `trivySha256`, `condition`. Sets `trivyDir`.

**steps/hadolint-steps.yml**: `dockerfile` (required), `hadolintVersion` (`2.15.1`), `hadolintSha256`, `condition`.

**steps/yq-install-steps.yml**: `yqVersion` (`4.47.1`), `yqSha256` (`''`), `condition`.

### scripts/ado/

All four scripts are idempotent and read their target from environment variables (`ORG` or `ORG_NAME`, `PROJECT`, `REPO`). [`examples/`](scripts/ado/examples/) holds sample manifests.

| Script | Does |
|---|---|
| `create-and-group-pipelines.sh <manifest>` | Registers pipelines (`-ci` first, so each CD can resolve its CI source) and moves them into one folder |
| `set-branch-policies.sh <manifest>` | Build-validation policies with path filters mirroring each `PR.yml` |
| `set-environment-approvals.sh [--approver id]... <env>...` | Approval check per Environment (`APPROVERS`, `REQUIRED_APPROVERS`, `TIMEOUT_MINUTES`; self-approval off) |
| `delete-unused-pipelines.sh [--apply] <name>...` | Dry run by default; deletes the policies first, then the pipelines |

## Validate

```bash
# YAML well-formedness (PyYAML)
python -c "import sys,yaml; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]" $(find platform/ci-templates -name '*.yml')
# Shell scripts
for f in platform/ci-templates/scripts/ado/*.sh; do bash -n "$f"; done
# Every inline `bash:` / `script:` / `inlineScript:` body: load each template with PyYAML and
# pipe the script text into `bash -n` (all 51 inline scripts in this repo pass).
```

The templates themselves can only be expanded by Azure DevOps (there is no offline expander), so the checks are syntax only: YAML structure and the shell inside it. The semver comparator in `gitops-promote-steps.yml` was unit-tested against the SemVer 2.0 precedence examples.

## KNOWN-GAPS

- **Stage/Demo promote "the dev image at approval time".** `Promote_Stage` and `Promote_Demo` copy whatever `apps/<app>/dev/image.yaml` holds when the approval is granted, paired with the chart of the `main` run. If `develop` moved on between the `main` merge and the approval, a newer image ships with that chart. The ordering guard protects the chart pin, not this pairing. A fix would record the dev digest in the `main` run and promote that.
- **Trivy and hadolint are warn-only.** This was a decision, because the dev CD's completion trigger only fires on successful runs. Findings are visible (tag, Tests tab, summary) but block nothing. Only gitleaks blocks.
- **`--secret-build-arg` is not a BuildKit secret mount.** `az acr build` has no `--secret` mount, so a private-feed token reaches the build as a build argument that ACR keeps out of its logs. The Dockerfile must consume it only in a discarded builder stage.
- **The yq checksum is verified against the release's own checksum file** unless `yqSha256` is pinned. This catches corruption, not a compromised release.
- **The licence gate is not wired in.** [`examples/licence-allowlist.json`](examples/licence-allowlist.json) shows its shape. It was taken out of the PR pipelines when it failed every PR on an internal package that declares `UNLICENSED`. The fix is an explicit, reasoned allow entry for internal packages, which has not been done yet.
- **Concurrent promotion of the same app** fails loudly on rebase rather than being re-validated against the new tip; the operator re-runs the stage.
