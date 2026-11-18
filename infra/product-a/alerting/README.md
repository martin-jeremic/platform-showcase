# alerting

This stack owns everything behind Alertmanager's notification credentials:

- the Entra app that Alertmanager sends mail as;
- one rotating client secret per cluster;
- one Logic App per Teams destination, which posts the card;
- every value, written straight into each cluster's Key Vault.

The consuming side is the observability chart (`platform/charts/observability`) and its
per-cluster overlay. This stack changes nothing in any cluster. It fills the vault
objects that the chart mounts.

| File | Objects | Per |
|---|---|---|
| [`entra.tf`](entra.tf) | App registration and service principal. **No Graph permission, no consent.** | org |
| [`entra.tf`](entra.tf) | Client secret, rotated by an apply after `secret_rotation_days`, valid for `secret_lifetime` | cluster |
| [`teams.tf`](teams.tf) | Teams API connection, authorised once by hand | org |
| [`teams.tf`](teams.tf) | Logic App: HTTP trigger, then post the card, then answer 200 (or 502 on failure) | destination |
| [`keyvault.tf`](keyvault.tf) | `alertmanager--graph-client-secret` | cluster |
| [`keyvault.tf`](keyvault.tf) | `alertmanager--teams-webhook-url` or `alertmanager--<audience>-teams-webhook-url` | destination |

## The two steps outside OpenTofu

1. **Authorise the Teams API connection.**
   - The Teams connector accepts only a delegated OAuth sign-in, and Graph has no
     app-only permission to post channel messages.
   - Sign in once, as a service account (not a person) that is a member of every team
     in `teams_channels`.
   - `check.teams_connection_authorized` warns on every plan until the status is
     `Connected`.
2. **Scope Mail.Send in Exchange Online** with
   [`exchange/Set-AlertingSenderScope.ps1`](exchange/Set-AlertingSenderScope.ps1).
   Exchange RBAC for Applications has no provider and no Graph API.
   - `tofu output -raw exchange_sender_scope_command` prints the complete invocation,
     so an Exchange administrator can run it without tofu and without access to this
     state, which holds the secrets.
   - The script is idempotent, and it ends by proving that every sender is in scope
     and that another mailbox is not.

### Why the app has no Graph permission

RBAC for Applications grants **add to** Entra grants; they do not override them. An
Entra `Mail.Send` (one click on "Grant admin consent") would let the app send as
every mailbox, and no Exchange scope could narrow it. So the app declares no Graph
permission, and the script refuses to run if the service principal holds any Entra
app-role assignment. If the Exchange step is missing, the app can send as nobody: it
fails closed. The legacy `ApplicationAccessPolicy` fails the other way: if the
policy is missing, the app can send as anyone.

## Prerequisites

| Who | Needs |
|---|---|
| Applier (Entra) | Application Administrator, Cloud Application Administrator or Application Developer. **Not** Privileged Role Administrator: nothing is consented. |
| Applier (Azure) | Contributor on the resource group's subscription; **Key Vault Secrets Officer** on every vault in `clusters` (RBAC-mode vaults ignore access policies). |
| Exchange step | Exchange Administrator; `ExchangeOnlineManagement` 3.x; Azure CLI signed in to the tenant (`az login --allow-no-subscriptions`). |

## Adding a cluster, an audience or a sender

Edit the defaults in [`variables.tf`](variables.tf), not a tfvars file.

- A new destination plans as adds only.
- Apply **before** the overlay change that enables it syncs. The CSI mount fails as a
  whole while any object it lists is missing.
- Re-run the Exchange line only if the sender is new to the map.
