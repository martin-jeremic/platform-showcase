# 0001 · Build once, promote by digest; the approval is the deployment

**Context.**
- Deployments were pushed from pipelines with `helm upgrade --set image.tag=…`.
- Each environment could receive a different build of "the same version".
- Nothing outside the pipeline log recorded what ran where.

**Decision.**
- **Build once.** CI builds an image once and resolves its immutable digest.
- **Promote by digest.** Promotion is an Azure DevOps deployment job bound to an approval-gated Environment. It writes `image.yaml` (the digest) and `release.yaml` (the exact chart version) into the GitOps repository in one commit.
- **Argo CD only reconciles.** It syncs the cluster to that commit.
- **Production copies stage.** Production receives the pair stage is running.

**Consequences.**
- **What runs where is answerable.** `grep -r digest apps/<svc>/*/image.yaml` shows it. The same digest in two folders means the same bits.
- **Rollback** is `git revert`.
- **Chart pins must never be a range** such as `"*"`. Semver ranges exclude prereleases, so an alpha pin fails with "version matching constraint not found".
- **Every writer to the GitOps repository retries** with fetch, rebase and push, because concurrent promotions race.
- **Two ordering hazards are guarded explicitly:**
  - Approving an old pending run could roll an environment back. The promote step refuses a pin older than the current one unless `allowDowngrade` is set.
  - The digest is read at approval time, so a develop build between the main run and the approval changes the payload. This is documented in [known gaps](../known-gaps.md).

**Lessons.** A federated Azure login inside one pipeline task is a client assertion that Entra caps at ten minutes. A remote image build longer than that made the digest lookup after it fail, leaving a good image and no recorded candidate. Build and record now run in two tasks, each with a fresh assertion.
