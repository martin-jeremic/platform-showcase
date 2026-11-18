locals {
  os_disk_type = var.ephemeral_os ? "Ephemeral" : "Managed"

  # System pool shape. Ephemeral OS disk sizes fit each SKU's temp/cache disk
  # (D2ds/E2ds_v5 = 75 GB, D8ds/E8ds_v5 = 300 GB). With managed OS disks the size
  # is left at the AKS default (null). The `d`-suffix SKUs are what make ephemeral
  # OS possible at all; the fallback to `s`-suffix SKUs exists because the
  # ephemeral variants are sometimes capacity-restricted in a region.
  system_pool = var.shape == "A" ? {
    vm_size         = var.ephemeral_os ? "Standard_D2ds_v5" : "Standard_D2s_v5"
    os_disk_size_gb = var.ephemeral_os ? 75 : null
    critical_only   = true # applies the CriticalAddonsOnly=true:NoSchedule taint
    } : {
    vm_size         = var.ephemeral_os ? "Standard_E8ds_v5" : "Standard_E8s_v5"
    os_disk_size_gb = var.ephemeral_os ? 300 : null
    critical_only   = false # Shape B: one node, every workload co-schedules
  }

  # User pools exist only in Shape A. Switching shape touches node pools only;
  # the control plane, identities and IPs are untouched.
  user_pools = {
    worker = {
      vm_size         = var.ephemeral_os ? "Standard_D8ds_v5" : "Standard_D8s_v5"
      os_disk_size_gb = var.ephemeral_os ? 300 : null
      node_taints     = []
    }
    infra = {
      vm_size         = var.ephemeral_os ? "Standard_E2ds_v5" : "Standard_E2s_v5"
      os_disk_size_gb = var.ephemeral_os ? 75 : null
      node_taints     = ["workload=infra:NoSchedule"]
    }
    monitoring = {
      vm_size         = var.ephemeral_os ? "Standard_D2ds_v5" : "Standard_D2s_v5"
      os_disk_size_gb = var.ephemeral_os ? 75 : null
      node_taints     = ["workload=monitoring:NoSchedule"]
    }
  }
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-product-a-demo"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  dns_prefix          = "aks-product-a-demo"
  sku_tier            = "Free"

  # Azure Workload Identity: the webhook that injects a federated token into pods
  # labelled azure.workload.identity/use=true. Needs the OIDC issuer. First
  # consumer: the Trivy scan jobs (trivy-identity.tf). Apply while the cluster is
  # RUNNING: AKS cannot update a stopped cluster.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Pinned to a MINOR, same model as prod. This used to float on the region's
  # latest (a data source), so any unrelated apply could jump a minor -- and fail,
  # because this cluster is usually stopped and AKS cannot upgrade a stopped
  # cluster. Minor-only lets AKS choose the patch; the patch channel keeps it
  # current whenever the cluster runs. No maintenance window: the cluster is
  # started by hand, so there is no predictable slot to schedule into.
  kubernetes_version        = var.kubernetes_version
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  identity {
    type = "SystemAssigned"
  }

  # No custom VNet: AKS creates and manages its own in the MC_* resource group.
  # Accepted trade-off for a disposable environment: the default node CIDR
  # (10.224.0.0/12) can never be changed, so this cluster is not peerable to
  # anything overlapping it. Prod owns its VNet for exactly that reason.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"

    # Egress pinned to our own static IP (network.tf) instead of the ephemeral
    # Azure-managed one, so the PostgreSQL firewall can trust a stable address
    # that survives cluster stop/start.
    load_balancer_profile {
      outbound_ip_address_ids = [azurerm_public_ip.aks_outbound.id]
    }
  }

  # KEDA was enabled on this cluster out-of-band before it was in config.
  # Declared here so an unrelated apply does not quietly disable it.
  workload_autoscaler_profile {
    keda_enabled = true
  }

  default_node_pool {
    name                         = "system"
    node_count                   = 1
    vm_size                      = local.system_pool.vm_size
    zones                        = ["1"] # deliberately non-HA, single zone
    os_disk_type                 = local.os_disk_type
    os_disk_size_gb              = local.system_pool.os_disk_size_gb
    only_critical_addons_enabled = local.system_pool.critical_only
    temporary_name_for_rotation  = "systemtmp" # lets shape switches rotate the pool in place

    # System pools cannot scale to 0, so autoscale 1<->2 only. The real off-hours
    # saving comes from stopping the whole cluster (automation.tf).
    auto_scaling_enabled = true
    min_count            = 1
    max_count            = 2

    # Tracks the cluster pin. Without it the pool keeps the patch it was created
    # with: the control plane moved a patch ahead while every pool stayed behind,
    # and a minor bump would have left them a minor behind.
    orchestrator_version = var.kubernetes_version

    node_labels = {
      pool = "system"
    }

    # Mirrors the server-side default AKS stamps on every pool. Without the block,
    # every plan diffs it away and Azure puts it straight back.
    upgrade_settings {
      max_surge = "10%"
    }
  }

  lifecycle {
    # The cluster autoscaler owns the live node count.
    ignore_changes = [default_node_pool[0].node_count]
  }

  tags = local.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  for_each = { for name, pool in local.user_pools : name => pool if var.shape == "A" }

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  mode                  = "User"
  node_count            = 1
  vm_size               = each.value.vm_size
  zones                 = ["1"]
  os_disk_type          = local.os_disk_type
  os_disk_size_gb       = each.value.os_disk_size_gb
  node_taints           = each.value.node_taints

  # Idle user pools drain to 0, so an idle *running* cluster costs one system node.
  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 3

  # Same as the system pool: without it a minor bump upgrades the control plane
  # only and these pools silently stay behind.
  orchestrator_version = var.kubernetes_version

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
