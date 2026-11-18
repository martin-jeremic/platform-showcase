# Dedicated worker pool for a legacy application suite migrating off a Windows/IIS
# host. "IIS" is what the services are LEAVING: the containers are Linux/amd64, so
# this is an ordinary Linux pool. That distinction is load-bearing -- a Windows pool
# would need a cluster-level windows_profile, and changing the network plugin is a
# cluster rebuild, not a pool change.
#
# WHY A SEPARATE POOL, when nodeSelector, taints and requests deliver isolation at
# zero infrastructure cost:
#   1. Capacity for an in-flight migration. The system pool is one node carrying the
#      services already in production; a batch more arriving during a cutover is
#      where a noisy neighbour would first become an outage.
#   2. The autoscaler can only remove nodes from a pool that holds nothing pinned
#      to it. These services have no volumes and no local state -- exactly the
#      disposable profile a scaling pool needs. The system pool holds kube-system
#      and can never scale down; this one can.
#
# REJECTED: raising node_count on the system pool. Cheaper to write, but one
# failure domain, one scheduling pool, and capacity that can never be released.
#
# ON/OFF: var.legacy_node_pool_enabled. The migration is paused, so the pool is off
# by default -- destroyed in Azure, not deleted from the repo. `count` rather than a
# commented-out block: the address stays legacy[0] either way and nothing else in
# the stack needs to know whether the pool exists.
resource "azurerm_kubernetes_cluster_node_pool" "legacy" {
  count = var.legacy_node_pool_enabled ? 1 : 0

  name                  = "legacy"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id

  vm_size         = var.legacy_node_vm_size
  os_disk_size_gb = 64

  # Follows the control plane rather than carrying its own version. The reference
  # also orders the apply: the cluster upgrades first, then this pool.
  orchestrator_version = azurerm_kubernetes_cluster.aks.kubernetes_version

  # User, not System. CoreDNS or metrics-server landing on a System pool carry no
  # disruption budget, so the autoscaler refuses to evict them and the pool sticks
  # at its high-water mark forever -- removing the only reason it autoscales.
  mode = "User"

  auto_scaling_enabled = true
  min_count            = 1
  max_count            = var.legacy_node_max_count

  # The label is what the pods select on; the taint keeps everything else off.
  # Both are needed and neither is sufficient. A contract with the legacy charts,
  # which must carry the matching nodeSelector and toleration -- until they do, the
  # pool sits empty, correctly and silently.
  node_labels = { workload = "legacy-app" }
  node_taints = ["workload=legacy-app:NoSchedule"]

  # vm_size and os_disk_size_gb are ForceNew on the pool; this turns a SKU change
  # into a rotation. The temp pool does not inherit taints or labels, so the pinned
  # pods do not schedule during the move: plan it as an outage window.
  temporary_name_for_rotation = "legacytmp"

  # No zones, deliberately: zonal nodes force zonal disks, which pin stateful pods
  # to one zone. The data tier (single-zone PostgreSQL, Basic SQL) caps
  # availability well below anything zone-spread compute would buy.

  lifecycle {
    # node_count is the autoscaler's. orchestrator_version is deliberately NOT
    # ignored: node-image updates do not touch it, and ignoring it would make the
    # pool skip every Kubernetes upgrade.
    ignore_changes = [node_count]
  }

  tags = var.tags
}
