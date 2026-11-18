# Releasing a chart change to the island

**A tag makes a version AVAILABLE; a descriptor bump makes it LIVE.**

| # | Step | Where | Who |
|---|---|---|---|
| 1 | Edit the chart; `Chart.yaml` `version` bumped | charts repo | you (CI auto-bumps the patch on the PR if you forgot) |
| 2 | Tag `<chart>-<version>` | charts repo | CI, on merge to main (`tools/chart-version.sh tag --push`) |
| 3 | `chartRevision: <chart>-<version>` in `platform/aks-product-a-prod/<chart>.yaml` | this repo | CI, right after the tag (`chart-version.sh promote`) |

A **values-only** change needs none of this: edit
`platform/values/aks-product-a-prod/<component>.yaml`, merge, and it is live on the
next sync. Values are deliberately not pinned -- see the appset header.

## The failure this guards against is silent

Edit a chart and do not raise its version, and:

- the tag already exists, so nothing new is cut;
- the descriptor still pins the old tag;
- Argo keeps rendering the **old** chart;
- the Application reports `Synced` and `Healthy`.

No error anywhere -- you find out when the fix you shipped has no effect. That is
why the charts CI bumps the patch version on the PR branch itself, and why a direct
push to main that skips the bump fails the build (`chart-version.sh check`) before
the Tag stage can run.

## The convention that makes automation trivial

```
tag name == <chart directory> + "-" + <Chart.yaml version>
```

`Chart.yaml` is the source of truth; a tag is cut from it, never the other way
round. No semver inference, no commit-message parsing. Idempotent: no version bump,
no tag, no side effect.

## Ordering: tag first, descriptor second

A descriptor that pins a tag origin does not have is a `ComparisonError` for that
Application. `promote` therefore reads `git ls-remote --tags origin` once and
skips -- with a warning -- any tag not there yet. It never references a tag it has
not seen on origin.

## Auto-promotion: a decision, not a default

The original recommendation was to automate the tag and keep the descriptor bump
manual, because auto-promotion collapses availability into liveness: every chart
merge deploys straight to production, rollback stops being "repoint the pin", and
the wave order becomes whatever order changes merged in.

It was overridden **for this cluster**: one cluster, one operator, who writes the
chart change and would have run the bump anyway. The invariants kept:

- a descriptor is only ever bumped to a tag that exists on origin;
- `component.sh validate` runs before every push;
- one `ci: promote <comp> -> <tag>[, ...]` commit per run -- **rollback is
  `git revert` of that commit**, and Argo converges on the next sync;
- tags are never moved (tag protection on `refs/tags/*`), so an old pin still means
  the same bytes;
- components without a descriptor (postgres-exporter, pending) are never promoted;
- a failed push (someone pushed meanwhile) is rebased and retried, not dropped.

If this ever grows to more clusters or more chart authors, the manual descriptor
bump is the first gate to reinstate -- which is exactly how the **hub** works: its
four clusters are bumped by a reviewed one-line PR (`component.sh bump`).

## Never move a tag

Git will let you retarget one, and doing so silently changes what an already-pinned
descriptor resolves to -- defeating the point of pinning and making a "rollback to
the last known good tag" land on different bytes than last week. The tooling cannot
move a tag (it skips any that exist), and tag protection stops a force-push. If tag
immutability ever needs stronger enforcement than that, THAT is the concrete trigger
to move to an OCI chart registry -- not a second cluster on its own.

## Manual fallback

```sh
# charts repo
sh tools/chart-version.sh bump traefik minor        # deliberate minor/major
sh tools/chart-version.sh tag                       # dry run: what would be cut
# this repo, after the tag is on origin
sh platform/component.sh bump aks-product-a-prod traefik traefik-1.3.0
sh platform/component.sh validate
```
