# Conclusion: two nodes for the org cluster, and add the node last

## Verdict

Two nodes is the right target for `aks-org-prod`. **Adding the node is the last step,
not the first.**

On the current configuration a second node buys little. Every workload runs one
replica, so a second node gives pods somewhere to be *rescheduled* after a failure.
It does not keep any of them serving through it. The outage gets shorter, but it does
not go away.

The availability comes from three changes, all free: replica counts, anti-affinity
and corrected requests. Without them the second node is idle capacity.

## What the second node does buy

- **A second failure domain.** Today a node failure has nowhere to go. Every pod
  waits until a replacement node joins and pulls its images, which takes minutes, and
  the whole platform is down at once.
- **Free rescheduling for stateful singletons.** This was verified live: nodes and
  persistent volumes are **non-zonal**, so a disk can attach to either node.
  - The product cluster is different. There, zonal disks pin stateful pods to one
    zone.
  - Do not add zones to this pool. The data tier is single-zone and Basic, so
    zone-spread compute would buy redundancy the data cannot match, and it would
    bring in disk pinning that does not exist today.
- **Node upgrades stop being outages.** Drains have somewhere to go.

## Prerequisites (they go in before the node)

1. Correct CPU requests ([`pool-rightsizing.md`](pool-rightsizing.md)). Raise the
   identity provider's memory request.
2. Set replicas to 2 for the ingress, the identity provider and the applications.
   Give each a **hard** hostname spread with `minDomains: 2`. Soft anti-affinity and a
   bare `maxSkew` both allow co-location and fail silently.
3. Add PDBs with `maxUnavailable: 1`, never `minAvailable` equal to the replica
   count, which blocks every drain.
4. Add PriorityClasses so the ingress and the identity provider outrank applications
   under pressure.
5. Then `node_count = 1 -> 2`. This is an online change, with no pool rotation.
6. Verify that each replicated workload sits on a different node, and that draining
   either node leaves the platform serving.

## Sizing

With two nodes, **each node must carry the whole platform alone** (N+1). That sets
the size, not current use. The node SKU that runs everything today is the only one
proven to do that. The half-memory variant fits today's requests, but not doubled
replicas plus the monitoring stack plus growth on a surviving node.

Changing the SKU is a pool rotation. Going from 1 to 2 nodes is not.

## Two risks that outrank the node decision

- **The database dumps went nowhere at first.** The backup storage, identity, role and
  lock existed ([`org/backup`](../org/backup/main.tf)), but no job wrote to them. The
  job had to land, and a restore had to be tested.
- **The database PVC used a `Delete` reclaim policy.** A namespace removal or an Argo
  CD prune would destroy the data. Stateful PVCs need a `Retain` storage class.

Both are cheaper than a node and protect against the failure mode that actually loses
data. Node redundancy only protects against hardware failure.

## When two becomes three

Two nodes is the most expensive way to be redundant: you buy 2x capacity and can
safely use 1x. Three nodes need a third less reserve for the same resilience. Move to
three, rather than to bigger nodes, when one node can no longer carry everything.
