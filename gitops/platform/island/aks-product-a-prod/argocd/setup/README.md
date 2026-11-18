# `argocd/setup/` -- one-time bootstrap of the island, deliberately unmanaged

Applied **by hand**, once, and **excluded from
[`../kustomization.yaml`](../kustomization.yaml)** so Argo CD never prunes it. A
repository credential managed by Argo could be pruned by Argo, and then nothing
could read the repo that would restore it. CI fails if any of it renders.

| File | Holds | Why it cannot come from Key Vault over CSI |
|---|---|---|
| `repo-creds-azure-devops.yaml` | nothing secret: a workload-identity repo-creds template | Argo needs it before it can sync anything |
| `secret-cloudflare-api-token.yaml` | the DNS-01 token | cert-manager mounts no volume; the driver only syncs while a pod mounts the SPC |
| `secret-oidc-client-secrets.yaml` | Argo CD + Grafana OIDC client secrets | neither pod mounts an SPC volume |
| `secret-grafana-admin.yaml` | Grafana break-glass admin | same |

Everything with a pod that can mount a volume -- RabbitMQ, Elasticsearch,
Keycloak, Alertmanager -- reads Key Vault over CSI with workload identity. The
Alertmanager receiver credentials used to be here too, as a hand-seeded Secret: it
was never applied on the production cluster, so the first sync that mounted it
left `alertmanager-0` in Init and no alert reached anyone. Its premise ("an
operator-managed pod cannot mount a CSI volume") was wrong; they now come from the
vault through `alertmanagerSpec.volumes`.

External Secrets Operator would solve the remaining four declaratively. It was
considered and not taken for the island: four hand-seeded secrets are cheaper than
an operator to own, upgrade and monitor. (The hub, with a fleet of cluster
registrations, did take it -- see chart argocd-cluster-registry.)

## Bootstrap order

1. The OpenTofu-installed controller is running, release **`argocd`**, namespace
   `argocd`, `fullnameOverride: argocd`. A different name means the wave-5
   self-management handoff stands up a PARALLEL install instead of adopting it.
2. `kubectl -n argocd replace -f repo-creds-azure-devops.yaml`.
3. The DNS-01 token (straight from the vault -- see the file), BEFORE wave 1.
4. `kubectl -n argocd apply -f ../root-application.yaml`, with ONLY the wave 0-2
   descriptors present. Then clear the edge gate before anything else syncs:
   ```sh
   kubectl get clusterissuer letsencrypt-prod          # READY True
   kubectl -n traefik get certificate                  # READY True
   kubectl -n traefik get gateway                      # PROGRAMMED True, address = the static IP
   curl -sI http://app.product-a.example.net/          # 301 -> https
   ```
   Every later component hangs an HTTPRoute off that Gateway; if the edge does not
   work, nothing after it will, in less obvious ways.
5. Seed the vault (`../../scripts/seed-secrets.ps1`) before waves 3-4.
6. After wave 4 (Keycloak) and before wave 5: the OIDC client secrets and the
   Grafana admin Secret.

Filled copies of these files are never written to disk or committed: pipe them
from the vault at apply time.
