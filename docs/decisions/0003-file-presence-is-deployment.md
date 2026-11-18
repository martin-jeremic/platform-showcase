# 0003 · File presence is deployment

**Context.**
- About 45 hand-written Applications existed, one per service per environment, and their copies had drifted apart.
- The chart pin lived in each Application's `targetRevision`, so promoting a release meant editing Argo manifests.

**Decision.**
- **Applications.** One ApplicationSet per environment, with a git-files generator over `apps/*/<env>/release.yaml`.
- **Platform.** One ApplicationSet per cluster, over `platform/<cluster>/*.yaml` descriptors that are validated against a `catalog.yaml`.
- **Strict templating.** `missingkey=error` makes a descriptor without a required field fail loudly.
- **Optional fields go through `templatePatch`.**
  - The CRD types booleans strictly, so a templated string inside `template:` is rejected.
  - A `{{ if }}` inside `template:` would also make the file invalid YAML for the kustomize render.

**Consequences.**
- **Adding a service** means adding a folder.
- **Removing it** means deleting its `release.yaml`. The resources finalizer cascades the deletion to the workload.
- **Values live outside the descriptor folder.** They go under `platform/values/<cluster>/`, never `platform/<cluster>/values/`. If the generator parsed a values file as a descriptor, generation would fail for every component on the cluster.

**Lessons: cutting over safely.**
1. Set the root Application to `prune: false` first.
2. Adopt one canary Application.
3. Use `applicationsSync: create-update` during the migration.
4. Freeze promotions until the cutover is done.
5. On rollback, delete with `--cascade=orphan`.
6. Switch AppProjects in two commits. First add the new projects at sync wave `-1`. Prune the transitional project only in the second commit, so no Application is ever left in a project that does not exist.
