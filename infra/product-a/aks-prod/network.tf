# ---------------------------------------------------------------------------
# Bring-your-own VNet.
#
# The one place prod deliberately does not mirror demo. Demo lets AKS create its
# own VNet in the MC_* resource group, so Azure picks the address space
# (10.224.0.0/12) and it can never change. Fine for a disposable environment; for
# prod it permanently forecloses peering to anything that overlaps -- another
# environment, a partner network, on-prem.
#
# Owning the VNet costs nothing (VNets and subnets are free; gateways, peering
# traffic and endpoints are not) and the cluster behaves identically.
#
# Address plan, everything under 10.10.0.0/16, far from Azure's default:
#
#   10.10.0.0/16   vnet-product-a-prod
#     10.10.0.0/22   snet-aks-nodes     (~1000 node/ILB addresses)
#     10.10.4.0/24   snet-privatelink   (empty today; Private Endpoints later)
#     10.10.5.0/24   RESERVED for a delegated PostgreSQL subnet, should PG ever
#                    move from public access to VNet injection. Injection is
#                    create-time only, so the room is booked now.
#     10.10.6.0/23+  free
#
#   10.244.0.0/16  pod CIDR      (overlay, not routed in the VNet)
#   10.11.0.0/16   service CIDR  (cluster-internal)
#
# With Azure CNI Overlay the pod CIDR is not consumed from the subnet, so node
# density is not limited by subnet size; neither range may overlap the VNet.
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "prod" {
  name                = "vnet-product-a-prod"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  address_space       = [var.vnet_address_space]

  # Replacing the VNet replaces every node pool bound to its subnet.
  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = azurerm_resource_group.prod.name
  virtual_network_name = azurerm_virtual_network.prod.name
  address_prefixes     = [var.subnet_nodes_cidr]
}

# Created empty. Private Endpoints need a subnet with endpoint network policies
# disabled, and carving one out later is a VNet edit under a running cluster.
# Reserving it now makes that an additive change.
resource "azurerm_subnet" "privatelink" {
  name                              = "snet-privatelink"
  resource_group_name               = azurerm_resource_group.prod.name
  virtual_network_name              = azurerm_virtual_network.prod.name
  address_prefixes                  = [var.subnet_privatelink_cidr]
  private_endpoint_network_policies = "Disabled"
}

# No NSGs. AKS manages the rules its own load balancer needs, and an NSG on the
# node subnet is a well-known way to break cluster networking in non-obvious ways.
# Add one only with a specific rule in mind.

# ---------------------------------------------------------------------------
# Public IPs, outside the MC_* resource group so they survive a cluster rebuild.
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "ingress" {
  name                = "pip-product-a-prod-ingress"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  sku                 = "Standard"
  allocation_method   = "Static"

  # Zone-redundant from day one and deliberately NOT tied to var.node_zones.
  # Changing a public IP's zones forces replacement, which changes the address and
  # silently breaks every DNS record -- and prevent_destroy would block it anyway.
  # Zone redundancy on a Standard IP costs nothing extra.
  zones = var.public_ip_zones

  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

# Static egress IP for the AKS load balancer: the address the PostgreSQL firewall
# and the alerting Logic App trigger (../alerting) trust.
resource "azurerm_public_ip" "aks_outbound" {
  name                = "pip-product-a-prod-aks-outbound"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  sku                 = "Standard"
  allocation_method   = "Static"
  zones               = var.public_ip_zones

  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

# RG-scoped: covers attaching the IPs above and the node pools joining the
# subnets, with no separate subnet-scoped grant.
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = azurerm_resource_group.prod.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# DNS is held at an external provider; nothing is created here. If prod is served
# on more than one hostname, the DNS-01 API token cert-manager uses needs edit
# rights on EVERY zone: a token scoped to one zone issues that name and silently
# never issues the others.
