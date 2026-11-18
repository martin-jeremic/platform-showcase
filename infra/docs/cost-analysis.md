# Cost analysis method

These analyses are repeatable, and each claim in them can be checked. Every number
comes from a command in the appendix of the analysis.

## Method

1. **Scope one stack at a time.** Price the resource group a stack creates (plus the
   `MC_*` group for a cluster). Keep a separate full-footprint document for
   everything the platform depends on, and state which document is the authority for
   which subtotal.
2. **Inventory live, read-only.** Use `az` and `kubectl` to find what is actually
   deployed:
   - node SKUs and counts per pool;
   - OS disk tier (it is VMSS-internal, not in `az disk list`);
   - PVC disks and their owners;
   - load balancer and public IPs;
   - schedules and the Automation job history (what really runs, not what the code
     says).
3. **Use retail rates, not the invoice.** Read prices from the public Azure Retail
   Prices API, one query pattern per meter. Invoice data was empty for the
   subscription type in use, and retail rates make the analysis reproducible by
   anyone.
4. **Measure, don't estimate, the usage-based meters.**
   - Log Analytics: daily ingestion per table, including weekdays versus weekends.
     The audit log only bills while the cluster runs.
   - Egress: the load balancer's byte counters over a week.
5. **Model the duty cycle explicitly.** Price at the hours the cluster really runs,
   from the job history. Then price the same stack 24/7 on demand, with a 1-year
   reservation, and with a 3-year reservation.
6. **Rank the savings, and name what blocks each one.** Each line gets a monthly
   saving and its blocker. Examples:
   - "consolidate the legacy pool", blocked by inflated CPU requests;
   - "Arm64 nodes", blocked by multi-arch images;
   - "Spot", not recommended at one replica.
7. **List what looks like a saving and isn't**, and what changed sign since the
   last analysis.
8. **List the gaps**: what the analysis could not measure.

## Findings that shaped the IaC

- **The declaration must reproduce production.** The committed schedule defaults
  differed from the live schedule, which was overridden in a git-ignored file. A clean
  checkout plus apply would have bought a longer day with a clean plan. The defaults
  now *are* the live schedule
  ([`org/aks-prod/variables.tf`](../org/aks-prod/variables.tf)).
- **The power schedule is the biggest lever, and its margin is thin.** It saves more
  than half the compute bill against running 24/7. But a 3-year reservation breaks
  even only slightly above the current working day. A longer day, or any weekend use,
  makes committing cheaper. The recommendation was "not yet, and here is the order",
  not "no".
- **One root cause blocks two savings.** Consolidating the dedicated pool and
  downsizing the system node were both impossible on paper because of declared CPU
  requests, not real load. That is the case for
  [`pool-rightsizing.md`](pool-rightsizing.md).
- **The cheapest cap is a quota.** The Log Analytics daily quota is a circuit breaker,
  set well above the baseline
  ([`org/aks-prod/monitoring.tf`](../org/aks-prod/monitoring.tf)).
