# Onboard a service

Prerequisite: the service meets the platform contract in [app/README.md](../../app/README.md). That means:
- configuration comes from environment variables;
- `/health/live` and `/health/ready` are separate endpoints;
- logs are JSON on stdout;
- the process drains on SIGTERM;
- it runs as a numeric non-root UID with a read-only root filesystem.

## 1. Service repository

1. **Add the deployment files.** Add a `Dockerfile`, a chart under `helm/<service>/` and `GitVersion.yml` (or `.releaserc.json` for Node services).
   - The chart's image helper must fail without a digest.
   - Config keys are written out explicitly; see [ADR-0005](../decisions/0005-explicit-config-keys.md).
2. **Add the pipelines.** Add `pipelines/{CI,CD,PR}.yml` that call the shared templates by tag. Copy an existing service; the templates carry all delivery logic.
3. **Register the pipelines and protect `main`:**
   ```bash
   platform/ci-templates/scripts/ado/create-and-group-pipelines.sh   # CI before CD: each CD references its CI by name
   platform/ci-templates/scripts/ado/set-branch-policies.sh          # build validation with path filters mirroring PR.yml
   ```
   Azure Repos ignores the YAML `pr:` block. The branch policy is the real PR contract.

## 2. Secrets

1. **List the secrets.** List every Key Vault object the chart's SecretProviderClass references, using the `<service>--<key>` naming.
2. **Seed every object before the first promotion.** One missing object fails the whole CSI mount, and the pod sits in `ContainerCreating` (see [ADR-0006](../decisions/0006-secrets-key-vault-csi-workload-identity.md)).
3. **Create the workload identity.** Add the service to `workload_identities` in the cluster's OpenTofu stack and apply.
4. **Copy the client id.** Put the **client id** (not the principal id) from `tofu output` into the environment's `values.yaml`.

## 3. GitOps repository

For each environment the service should run in, create `apps/<service>/<env>/`:

| File | Who writes it | First content |
|---|---|---|
| `values.yaml` | You | Every key the chart declares as owned, stated explicitly (the PR check enforces this) |
| `release.yaml` | The first approved promotion | Do **not** create it by hand unless the destination must be seeded (gitops/services) |
| `image.yaml` | The first approved promotion | Not created by hand |

The service starts running in an environment only when the first promotion writes `release.yaml`. Approving that promotion is the deployment.

## 4. Verify

```bash
# The pinned chart renders exactly as Argo will render it
helm template <svc> oci://<registry>/helm/<svc> --version <x.y.z> \
  -f apps/<svc>/<env>/values.yaml -f apps/<svc>/<env>/image.yaml

# Application healthy, and the route is attached to the HTTPS listener
kubectl -n <ns> get httproute <svc> -o jsonpath='{.status.parents[*].conditions}'
```

Check that the route reports `Accepted=True` and `ResolvedRefs=True` on `sectionName: websecure`. A route that is accepted only on `web` serves plain HTTP.
