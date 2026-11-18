resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  dns_prefix = var.cluster_name
  sku_tier   = var.sku_tier

  # Control-plane version, and -- through orchestrator_version on the default pool
  # -- the system pool's too. One variable feeds both so they cannot be raised
  # apart; the legacy pool (nodepools.tf) follows this attribute the same way.
  #
  # There is deliberately NO ignore_changes on either. There used to be, on the
  # premise that AKS auto-patches the cluster and the patch would show as drift.
  # Neither half held: the upgrade channel was "none", so nothing auto-patched; and
  # the value is a minor ALIAS ("1.36") that AKS stores exactly as sent -- the
  # resolved patch is reported separately in current_kubernetes_version -- so a
  # patch change produces no diff anyway. What the guard DID do was make
  # var.kubernetes_version a no-op: raising it planned nothing at all.
  #
  # One minor per apply: AKS rejects a skipped minor on a non-LTS cluster.
  # Procedure: ../../docs/aks-minor-upgrade.md.
  kubernetes_version = var.kubernetes_version

  # The gap the above exposed, now closed: patches and node images arrive on their
  # own inside the maintenance windows below, while minors stay a reviewed change
  # to var.kubernetes_version. Safe only because the version is a minor alias --
  # under a patch pin the channel would read as drift on every plan, which is why
  # variables.tf refuses a patch pin.
  automatic_upgrade_channel = "patch"
  node_os_upgrade_channel   = "NodeImage"

  # The windows must sit INSIDE the hours the cluster runs. The power schedule
  # (automation.tf) stops it every evening and all weekend, AKS cannot upgrade a
  # stopped cluster, and a Sunday-night window -- the obvious choice, and the one
  # the product cluster uses -- would simply never fire here.
  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Wednesday"
    start_time  = "10:00"
    utc_offset  = "+00:00"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Thursday"
    start_time  = "10:00"
    utc_offset  = "+00:00"
  }

  # Entra ID is the only way in. Left enabled, AKS keeps a certificate-backed
  # `clusterAdmin` account that anyone with listClusterAdminCredential can
  # download, and every action taken with it is logged as the shared,
  # unattributable user `masterclient` -- which would make the audit trail in
  # monitoring.tf meaningless. The certificate also cannot be revoked per person.
  #
  # Trade-off accepted: no break-glass login if Entra is unreachable.
  local_account_disabled = true

  # Already the default; stated so the posture is readable. ForceNew -- free now,
  # expensive to discover later.
  role_based_access_control_enabled = true

  # Azure Workload Identity: the issuer publishes the discovery document, the
  # webhook projects tokens into labelled pods. Neither works alone. First
  # consumers: ../backup and ../identities/trivy. Set rather than inherited: both
  # are Optional+Computed, so omitting them records whatever the API decides.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Managed VPA. Cluster-wide CPU requests were an order of magnitude above actual
  # use, and every capacity decision here is made on requests. The recommender
  # replaces the guess with a measurement. Enabling the add-on changes no pod;
  # requests move only where a VerticalPodAutoscaler object opts a workload in.
  # (../../docs/pool-rightsizing.md)
  workload_autoscaler_profile {
    keda_enabled                    = false
    vertical_pod_autoscaler_enabled = true
  }

  # Declared, not left to the provider. network_plugin and network_plugin_mode are
  # ForceNew, so these MUST equal what the live cluster was created with (read from
  # `az aks show --query networkProfile`); an import-style plan proves it. Declaring
  # them is what allows the egress IP to be pinned: the default managed outbound IP
  # lives in the MC_* group and can change on a rebuild, which breaks every
  # downstream allow-list (the SQL and PostgreSQL firewalls, the alerting Logic App).
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    load_balancer_sku   = "standard"

    load_balancer_profile {
      outbound_ip_address_ids = [azurerm_public_ip.egress.id]
    }
  }

  # Single fixed-size system pool, no autoscaling. Memory-optimised AMD SKU sized
  # to carry the whole platform alone (../../docs/two-node-ha.md).
  default_node_pool {
    name            = "system"
    vm_size         = var.node_vm_size
    node_count      = var.node_count
    os_disk_size_gb = var.node_os_disk_size_gb
    type            = "VirtualMachineScaleSets"

    # Omitted, a kubernetes_version bump upgrades the control plane only and
    # leaves this pool behind until the version skew limit blocks the next upgrade.
    orchestrator_version = var.kubernetes_version

    # vm_size and os_disk_size_gb are ForceNew on the CLUSTER, not the pool.
    # Without this, changing the SKU or disk size plans a destroy/recreate of the
    # whole cluster: new node resource group, new kubelet identity, every role
    # assignment rebuilt, a new OIDC issuer URL, PVCs orphaned. With it, the
    # provider rotates the pool through a temporary one, cluster untouched.
    #
    # The rotation runs at double node_count (regional vCPU quota must cover it),
    # and the temp pool inherits config but NOT taints or labels.
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # Authentication: the API server validates Entra tokens, so tenant policy (MFA,
  # Conditional Access) applies with no cluster-side configuration.
  #
  # Authorisation stays native Kubernetes RBAC (azure_rbac_enabled = false): the
  # full RBAC vocabulary, and bindings that are ordinary cluster config Argo CD can
  # own (platform/charts/rbac). Subjects are Entra group object IDs.
  #
  # admin_group_object_ids is the ONE binding AKS creates itself: cluster-admin.
  # It lives here because it is needed to onboard Argo CD at all.
  azure_active_directory_role_based_access_control {
    tenant_id              = data.azuread_client_config.current.tenant_id
    admin_group_object_ids = [azuread_group.admins.object_id]
    azure_rbac_enabled     = false
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}
