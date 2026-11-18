# 0017 · Cost controls

**Decision.**
- **Off-hours stop and start.**
  - Non-production AKS clusters stop outside office hours. Their node VMs are deallocated, and etcd is preserved.
  - An Automation runbook does this, running as its own managed identity.
  - That identity holds a custom role with exactly three actions: read, start and stop. The built-in AKS Contributor role includes `listClusterAdminCredential`, which would defeat disabling local accounts.
- **Requests sized to usage.**
  - CPU requests are cut to observed usage, because CPU is compressible.
  - Memory requests are left alone, because they drive eviction.
- **HA added last.**
  - High availability for the single-node company cluster is planned as a second node.
  - That node is added last. First come replicas, hard anti-affinity and honest requests; without them, a second node buys capacity, not availability.
- **One `ha` switch on the production cluster.**
  - It flips only settings that can change in place: the control-plane SLA tier, pool floors, database HA, and hard versus soft anti-affinity.
  - Settings that can only be chosen at creation are fixed at production values from day one: zones, storage redundancy and geo-backup.

**Lessons.**
- **A hand-set UTC offset breaks across DST.** The offset in a schedule's start time fixes the wall-clock time, so a hand-set `+02:00` is wrong for half the year. The offset is now computed from the anchor date.
- **Ignoring the start time hid drift.** `ignore_changes` on a schedule's start time let the live schedule drift from the declared one. The anchor is now derived, and the drift is checked.
- **Track the billing model, not only spend.** A subscription silently converted from a credit-based offer to pay-as-you-go, with no budgets set. Cost tracking now includes the billing model itself.
