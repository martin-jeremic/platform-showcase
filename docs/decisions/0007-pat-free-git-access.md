# 0007 · PAT-free Git access for an on-prem Argo CD

**Context.**
- Argo CD on the on-prem hub read Azure DevOps using personal access tokens. They expire, they belong to a person, and they get copied into Secrets.
- One expired token stopped reconciliation of a whole repository for weeks, and nothing alerted.

**Decision.**
- **Publish the hub's OIDC issuer.**
  - The hub API server's OIDC discovery document and JWKS are published through the Gateway.
  - Exactly two routes, each an Exact match rewritten to the API server's own path.
  - Anonymous callers are bound to the built-in `system:service-account-issuer-discovery` role.
- **Federate a managed identity.** A user-assigned managed identity is federated with Argo CD's repo-server ServiceAccount.
- **Grant it Azure DevOps access.** The identity is entitled in Azure DevOps with a Basic licence and made a project Reader.
- **One credential template.**
  - A `repo-creds` template with `useAzureWorkloadIdentity: "true"` covers every repository under the organisation URL prefix.
  - Repository Secrets carry no credential and inherit it.

**Consequences.**
- **Nothing to store or rotate.**
- **The issuer URL must match exactly.** It must equal the API server's *first* `--service-account-issuer` flag, byte for byte.
- **Roll out issuers additively.** Add the new issuer first and keep the old one, so existing tokens still validate.
- **Use a managed identity, not an app registration.** Nobody can attach a client secret to a managed identity, so it cannot drift back into a stored credential.

**Lessons.**
- **The Basic licence is called `express`.** That is the licensing API's name for it. Writing `basic` passes provider validation, then falls back to "no licence" and fails.
- **Apply the credential-less Secret with `kubectl replace`, not `apply`.** Otherwise the old token survives in the last-applied annotation.
