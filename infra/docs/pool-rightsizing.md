# Pool rightsizing: correct CPU requests, nothing else

## The finding

On both production clusters, the scheduler refused pods because the **declared**
CPU requests said the nodes were full, while measured CPU use was a small fraction
of that. One example: a single message-broker pod sat `Pending` for over an hour
while the node's real use was a few percent. The cause was prod overlays that
doubled each chart's request ("prod should get more") as a rule rather than from
measurement.

The gap was large: cluster-wide CPU requests were roughly an order of magnitude
above use. Memory requests were broadly accurate.

## The change

- **CPU requests only.** Edit the per-cluster overlays down to measured use plus
  headroom.
- **Memory requests and every `limits` block stay as they are.** The measurements
  came from an idle cluster, and memory is incompressible: an under-declared memory
  request becomes an eviction under pressure. Memory waits for a measurement window
  with real traffic.
- One exception went the other way. The identity provider's memory request was
  *below* its own use, which made it the first eviction candidate. It was raised.
- The cluster now runs the managed VPA add-on in recommendation mode, so later
  corrections are measured rather than guessed
  ([`org/aks-prod/main.tf`](../org/aks-prod/main.tf)).

Nothing about requests lives in this folder. The node pools are IaC; the requests
belong to the platform charts.

## The product cluster: three infra nodes down to two

The infra pool ran three nodes although its total requests fit on two. The real
blocker was **packing**: both replicas of the identity provider always landed on the
same node.

Root cause: its `topologySpreadConstraints` selector matched **zero pods**. The chart
labelled pods with the chart name, but the selector used the bare app name. With no
matching pods, skew is always 0, so the constraint was vacuously satisfied for any
placement. It **fails open and silently**, and `kubectl get -o yaml` shows a hard
constraint that looks correct.

The fix had three parts:

- correct the selector;
- add `minDomains`;
- verify every other spread constraint against live pod labels (the others matched).

After that, two nodes were reachable. The pool's floor stays at **2**, because nine
platform workloads run two replicas under a hard hostname spread
([`product-a/aks-prod/aks.tf`](../product-a/aks-prod/aks.tf)).

## Lesson

Capacity decisions (autoscaler thresholds, pool sizes, node counts) are made on
requests. Correct the requests before buying or removing nodes. Otherwise the
hardware is sized to fiction.
