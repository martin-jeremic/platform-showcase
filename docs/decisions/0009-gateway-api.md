# 0009 · Gateway API on Traefik

**Decision.**
- **One shared Gateway per cluster**, owned by the `traefik` chart, with two listeners:
  - `web` serves plain HTTP;
  - `websecure` serves HTTPS and terminates TLS with a cert-manager certificate.
- **Application routes bind to `websecure`.** Every application HTTPRoute sets `sectionName: websecure`. Without a section name, a route binds to both listeners and is also served over plain HTTP.
- **One redirect HTTPRoute, bound only to `web`,** answers every HTTP request with a 301 to HTTPS. If it were bound to both listeners it would loop.
- **The chart vendors the Gateway API CRDs** in `crds/`, together with the upstream `safe-upgrades` ValidatingAdmissionPolicy. That policy is a one-way ratchet: it blocks downgrading the CRD bundle.
- **A `TLSOption` sets the TLS floor**: TLS 1.2 or later, AEAD ciphers only. Its namespace is `required` from the provider setting, so the two cannot drift apart.

**Lessons.**
- **Hostname matching is exact, and failures are silent.** A wrong hostname shows `NoMatchingParent`, or binds only to HTTP, while Argo stays green.
- **Remove inert settings.** The `route.tls` blocks in application values were read by no template. They were removed rather than left to mislead.
- **Path-prefixed SPAs depend on their build.** These SPAs bake their prefix in at build time, so changing a path without a rebuild 404s every asset. Product B sets `<base href>` at runtime instead, through nginx `sub_filter`, so one image serves any prefix.
