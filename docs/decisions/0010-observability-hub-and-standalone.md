# 0010 · Observability: OTLP mTLS hub for LAN spokes, standalone stacks elsewhere

**Decision.**
- **LAN spokes ship everything to the hub.** Each spoke runs an Alloy DaemonSet, node-exporter and kube-state-metrics.
  - Every signal is stamped with `cluster`.
  - Everything leaves through one OTLP gRPC export with client-certificate mTLS to the hub's ingest gateway.
- **The hub routes each signal to its store.**
  - **Metrics** go to Prometheus' remote-write receiver.
  - **Logs** go to Loki, with the tenant taken from the `cluster` label.
  - **Traces** go to Tempo, through one filter and exporter per spoke, each with its own `X-Scope-OrgID`.
- **Client certificates come from the hub's cert-manager CA.**
  - Each bundle is copied once into the spoke's Key Vault and mounted through CSI.
  - The validity is long on purpose, because a copy cannot follow renewal.
- **Internet-facing AKS clusters run a full standalone stack,** with their own Alertmanager.
- **Log alerts are LogQL rules evaluated by Loki's ruler.** They go to the same Alertmanager. The rules are mounted by a sidecar into a per-tenant folder.

**Consequences.**
- **The hub holds one shared metrics store.** Metrics multi-tenancy is deferred.
- **Spans without a `cluster` attribute are dropped** by the per-spoke filters. This is accepted.

**Lessons.**
- **Replacing a values list drops the chart's defaults.** Restating the kubelet relabelings without `metrics_path` silently darkened the stock dashboards.
- **A duplicate YAML key silently re-enabled two disabled control-plane monitors.** In YAML, the later key wins.
- **Alert on "was there, now gone", not on `absent()`.** A label-only "absent" alert fires forever on a decommissioned target. The rule "was there in the last 7 days, now gone" (`max_over_time(...[7d]) unless ...`) stops on its own a week after decommissioning.
- **Two priority tiers fixed a Pending node agent.** Node agents run at `system-node-critical`, so they can preempt platform pods. Platform pods run at `system-cluster-critical`, so they can reschedule elsewhere.
