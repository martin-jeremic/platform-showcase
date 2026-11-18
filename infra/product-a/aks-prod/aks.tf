locals {
  os_disk_type = var.ephemeral_os ? "Ephemeral" : "Managed"

  system_pool = var.shape == "A" ? {
    vm_size         = var.ephemeral_os ? "Standard_D2ds_v5" : "Standard_D2s_v5"
    os_disk_size_gb = var.ephemeral_os ? 75 : null
    critical_only   = true # CriticalAddonsOnly=true:NoSchedule
    } : {
    vm_size         = var.ephemeral_os ? "Standard_E8ds_v5" : "Standard_E8s_v5"
    os_disk_size_gb = var.ephemeral_os ? 300 : null
    critical_only   = false
  }

  # max_count is per pool rather than a shared literal so `monitoring` can be
  # pinned. min_count differs from demo: see the notes on each pool.
  user_pools = {
    worker = {
      vm_size         = var.ephemeral_os ? "Standard_D8ds_v5" : "Standard_D8s_v5"
      os_disk_size_gb = var.ephemeral_os ? 300 : null
      node_taints     = []
      min_count       = var.ha ? 1 : 0
      max_count       = 3
    }
    infra = {
      vm_size         = var.ephemeral_os ? "Standard_E2ds_v5" : "Standard_E2s_v5"
      os_disk_size_gb = var.ephemeral_os ? 75 : null
      node_taints     = ["workload=infra:NoSchedule"]

      # 2, NOT 1. This floor is set by the CHARTS, not by var.ha: nine platform
      # workloads run 2 replicas under a hard hostname spread
      # (topologySpreadConstraints, maxSkew 1, DoNotSchedule) -- the ingress, the
      # identity provider, reloader, the Argo CD server and repo-server, and the
      # three cert-manager components. On one node the SECOND replica of every one
      # of them is unschedulable, the edge and the GitOps controller included.
      #
      # It used to be 1 while var.ha was false, which let the autoscaler drain to a
      # state the platform cannot run in. That would have surfaced during a node
      # drain, i.e. during an automatic patch upgrade, i.e. unattended.
      #
      # Argo CD also lives here (argocd.tf), and a cold pool means the helm_release
      # waits on the autoscaler during install. See ../../docs/pool-rightsizing.md
      # for how this pool went from three nodes to two.
      min_count = 2
      max_count = 3
    }
    monitoring = {
      vm_size         = var.ephemeral_os ? "Standard_D2ds_v5" : "Standard_D2s_v5"
      os_disk_size_gb = var.ephemeral_os ? 75 : null
      node_taints     = ["workload=monitoring:NoSchedule"]

      # PINNED AT EXACTLY ONE NODE.
      #
      # min 1, not 0: every workload here owns a ReadWriteOnce PVC (Prometheus,
      # Grafana, Loki, Tempo). A pool allowed to drain to zero strands all four;
      # the pods go Pending with no obvious cause, which reads as a slow install
      # rather than a missing node.
      #
      # max 1, not 3: all of these workloads are singletons with no spread
      # constraints, so one node is the correct shape and measured demand fits it
      # with room. Two nodes cost twice as much and buy no availability, because a
      # ReadWriteOnce volume pins its pod to one node regardless.
      #
      # !! The binding constraint is DISKS, not CPU or memory. Standard_D2ds_v5
      # allows 4 attached data disks and this stack needs exactly 4 -- the pool
      # lands at 4/4 with ZERO spare. A fifth stateful component here does not
      # schedule, and no amount of scaling out helps because the disks cannot span
      # nodes. Standard_D4ds_v5 costs the same as two D2ds_v5 and offers 8 slots;
      # that is the move when a fifth is needed.
      min_count = 1
      max_count = 1
    }
  }
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-product-a-prod"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  dns_prefix          = "aks-product-a-prod"

  # Free until var.ha; Standard buys the control-plane uptime SLA. In-place.
  sku_tier = var.ha ? "Standard" : "Free"

  # Pinned to a minor: a prod cluster must not jump a minor because someone re-ran
  # apply. Minor-only lets AKS choose the patch, which the patch channel then keeps
  # current inside the maintenance window. Minor upgrades stay a deliberate change
  # to var.kubernetes_version (../../docs/aks-minor-upgrade.md).
  kubernetes_version        = var.kubernetes_version
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true # federated pod identity, no in-cluster secrets
  azure_policy_enabled      = true # Gatekeeper; audit-only until policies are assigned

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip

    load_balancer_profile {
      outbound_ip_address_ids = [azurerm_public_ip.aks_outbound.id]
    }
  }

  workload_autoscaler_profile {
    keda_enabled                    = true
    vertical_pod_autoscaler_enabled = true
  }

  # Private by default. The source rendered this block only when the list was
  # non-empty and defaulted the list to empty, i.e. an API server open to the
  # internet unless someone remembered. Now an empty list is refused unless
  # var.allow_public_api_server is set explicitly (variables.tf), so "public" is a
  # visible decision in the tfvars, not a forgotten default.
  #
  # This is the changeable lever used instead of a private cluster:
  # private_cluster_enabled is create-time only and needs VPN or bastion access.
  dynamic "api_server_access_profile" {
    for_each = length(var.api_server_authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_server_authorized_ip_ranges
    }
  }

  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = "+00:00"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "06:00"
    utc_offset  = "+00:00"
  }

  default_node_pool {
    name       = "system"
    node_count = 1

    # Tracks the cluster pin, same as the user pools. Without it the system pool
    # keeps the patch AKS resolved at create time and silently stays a minor behind
    # when var.kubernetes_version is bumped -- which is exactly what happened on one
    # minor upgrade: control plane and user pools moved, this pool stayed. And
    # because that recorded request is a PATCH pin, the patch channel never crossed
    # the minor to fix it.
    orchestrator_version = var.kubernetes_version

    vm_size                      = local.system_pool.vm_size
    zones                        = var.node_zones
    vnet_subnet_id               = azurerm_subnet.nodes.id
    os_disk_type                 = local.os_disk_type
    os_disk_size_gb              = local.system_pool.os_disk_size_gb
    only_critical_addons_enabled = local.system_pool.critical_only
    temporary_name_for_rotation  = "systemtmp"

    # Under var.ha the floor rises to 3 so the control-plane add-ons survive the
    # loss of a node (and of a zone, once node_zones allows it).
    auto_scaling_enabled = true
    min_count            = var.ha ? 3 : 1
    max_count            = var.ha ? 5 : 2

    node_labels = {
      pool = "system"
    }

    upgrade_settings {
      max_surge = "10%"
    }
  }

  lifecycle {
    ignore_changes = [default_node_pool[0].node_count]

    prevent_destroy = true
  }

  tags = local.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  for_each = { for name, pool in local.user_pools : name => pool if var.shape == "A" }

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  mode                  = "User"
  node_count            = 1

  # Without this, bumping var.kubernetes_version upgrades the control plane only;
  # AKS does not carry a minor upgrade into a pool the provider is not versioning.
  # Minor-only: AKS records the requested alias ("1.37") separately from the
  # resolved patch, so this neither fights the patch channel nor drifts.
  orchestrator_version = var.kubernetes_version
  vm_size              = each.value.vm_size
  zones                = var.node_zones
  vnet_subnet_id       = azurerm_subnet.nodes.id
  os_disk_type         = local.os_disk_type
  os_disk_size_gb      = each.value.os_disk_size_gb
  node_taints          = each.value.node_taints

  auto_scaling_enabled = true
  min_count            = each.value.min_count
  max_count            = each.value.max_count

  node_labels = {
    pool = each.key
  }

  upgrade_settings {
    max_surge = "10%"
  }

  lifecycle {
    ignore_changes = [node_count]
  }

  tags = local.tags
}
