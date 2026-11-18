# 0005 · Config keys are written out, never generated with `range`

**Context.**
- A ConfigMap template ranged over a values map with `{{ if $val }}` to skip empty keys.
- That dropped an intentionally empty key, `WriterRuntimeRole: ""`, meaning "do not switch role".
- With the key gone, the application fell back to a default that meant the opposite, and three environments ran with inverted behaviour.

**Decision.**
- **Named keys only.** Every ConfigMap key is a named line in the template. Each key states its emptiness policy: it is either omitted when empty or rendered unconditionally.
- **CI guard.** The PR Helm stage fails on any `{{ range` in chart templates. Ranging over lists of objects is allowed; ranging over configuration keys is not.
- **Required keys fail early.** A required key uses `required`, so an empty value fails the render instead of shipping a placeholder.

**Consequences.** Every new key is a chart change. That is intended: the key becomes visible in review and in the perturbation check ([0004](0004-gitops-values-are-the-single-source.md)).
