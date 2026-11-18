# Argo CD access

## Model

- **Authentication.** People sign in through Keycloak, which puts the user's group names in the `groups` claim.
  - The `groups` mapper must use `full.path=false`. With a leading slash, no group matches.
- **Deny by default.** `policy.default` is empty, so a signed-in user with no group can see nothing.
- **One AppProject per environment or cluster.** Each project has a `developer` role bound to one Keycloak group.

  | The role allows | The role does not allow |
  |---|---|
  | `applications get` | update |
  | `applications sync` | delete |
  | `applications action/*` (e.g. restart) | override |
  | `logs get` | exec (disabled hub-wide) |
  | | create |

  Deploying a new version is not a role permission. It is the approval-gated promotion.
- **Hub and identity projects are admin-only.** A role that can sync Argo CD itself can rewrite its own RBAC.
- **Keycloak declares, people assign.** Groups are declared in OpenTofu. Membership is managed by people in the Keycloak console.

## Grant access

1. Add the person to the Keycloak group for that environment.
2. They sign out and back in, because group membership is read at login.

## Add an environment or project

1. **Create the project.** Add the AppProject file with `argocd.argoproj.io/sync-wave: "-1"`, so the ApplicationSet controller never sees an Application whose project does not exist yet.
2. **Point the ApplicationSet at it.** Set the ApplicationSet's `project:` field, and add the project file to the kustomization.
3. **Declare the Keycloak group** in OpenTofu and apply.
4. **Validate the policy offline before merging.** One malformed policy line disables every policy of that project, and nothing validates it on sync.
   ```bash
   kubectl -n <argocd-ns> exec deploy/<argocd-server> -- argocd admin settings rbac validate --policy-file - < policy.csv
   kubectl -n <argocd-ns> exec deploy/<argocd-server> -- argocd admin settings rbac can \
     'proj:<project>:developer' sync 'applications' '<project>/<app>' --policy-file - < policy.csv
   ```

## Debug "permission denied"

- **Check the server log.** Grep it for `casbin`. It names the subject and the exact object that was denied.
- **Check the token.** Decode it at the Argo CD user-info endpoint, and confirm the `groups` claim holds the plain group name.
- **Know the CLI limit.** `argocd login --sso` does not work against a confidential client. Use the UI, or a short-lived project token.

## Known limit

Keycloak lets a user edit their own group membership unless realm roles are tightened. Until that finding is closed, the RBAC boundary is organisational, not technical. See [known gaps](../known-gaps.md).
