# Rotate secrets

Secrets live in Key Vault and reach pods through the CSI driver. Rotation never needs a commit.

## Application secrets

1. **Write the new value as a new Key Vault version.** Use `az keyvault secret set --name <service>--<key> --file <path>`. Prefer `--file` to `--value`, so the value never appears in shell history or process lists.
2. **Wait for the driver.** The CSI driver polls on its rotation interval (5 minutes) and updates the synced Kubernetes Secret.
3. **Let Reloader restart the pods.** It watches that synced Secret and rolls the workload. Environment variables are read only at start, so this rollout is required.
4. **Verify:**
   ```bash
   kubectl -n <ns> get pods -l app.kubernetes.io/instance=<svc> -o wide   # new pod age
   kubectl -n <ns> describe pod <pod> | grep -i -A3 secrets-store       # no mount errors
   ```

On clusters without workload identity, if rotation silently stops, check that the credentials Secret still carries `secrets-store.csi.k8s.io/used=true`.

## Keys shared by two services

Some keys must hold the same value in two services. An example is the encryption key that protects stored integration credentials: one service writes those credentials and another reads them.

- Generate the value **once** and write it to both Key Vault objects in the same change.
- The active key id is a ConfigMap value (not a secret). Rotating to a new key is therefore a values change plus a new object, never an image rebuild.

## Alerting credentials

The Graph client secret and the Teams webhook URL are managed by OpenTofu (`infra/*/alerting`).

1. **Apply when it is due.** A `time_rotating` resource schedules the replacement. A `check` block warns when the current secret is within 60 days of expiry.
2. **Replacement is gapless.** The new password is created before the old one is destroyed, and is written as a new Key Vault version.
3. **No restart needed.** Alertmanager reads the credentials as files mounted by CSI, so it picks up the new value on the next poll.

## Credentials that cannot rotate automatically

These are seeded by hand from the `setup/` placeholders, and rotated the same way:
- the ACME DNS-01 token;
- the Argo CD and Grafana OIDC client secrets;
- the Grafana admin password.

Generate values with a CSPRNG, and never echo them. See `gitops/platform/island/aks-product-a-prod/scripts/seed-secrets.ps1`.

## A credential leaked into Git

1. **Rotate first.** Treat the credential as compromised from the moment it was committed.
2. **Then clean the history.** Rewrite it with `git filter-repo`.
3. **Then add a gitleaks rule or allowlist entry**, so the same class of leak is caught in PR.
