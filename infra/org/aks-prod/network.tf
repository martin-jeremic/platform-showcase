# Reserved addresses. An A record is a promise about a specific address; an
# address AKS allocates on demand belongs to the Service that asked for it, so
# recreating the ingress can hand back a different one. Reserving them inverts the
# ownership: the address outlives the controller, the cluster and a rebuild of this
# stack. Both live in this resource group, not in MC_*, which is created and
# destroyed with the cluster.

resource "azurerm_public_ip" "ingress" {
  # A literal, not a variable: renaming replaces the resource and changes the
  # address. It is not a knob.
  name                = "pip-org-prod-ingress"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  # Standard is not a preference: the cluster's load balancer is Standard and will
  # not attach a Basic IP. Standard implies static, which is what makes it DNS-safe.
  sku               = "Standard"
  allocation_method = "Static"

  # `zones` omitted: the default is zone-redundant, strictly better than pinning one
  # zone at the same price. The node pool declares no zones, so nothing to match.

  # The ADDRESS is the asset. A plain `tofu destroy` of the stack now fails here;
  # tearing it down has to be deliberate.
  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

# The address every pod egresses from (main.tf network_profile). Downstream
# allow-lists name it: database firewalls and the alerting Logic App trigger.
resource "azurerm_public_ip" "egress" {
  name                = "pip-org-prod-egress"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard"
  allocation_method   = "Static"

  lifecycle {
    prevent_destroy = true
  }

  tags = var.tags
}

# The AKS load balancer can only attach an IP it holds rights over. Without this
# the ingress Service sits in `Pending` indefinitely, reporting no reason.
#
# Resource-group scope, not the IP: when the Service selects its IP by ADDRESS
# (loadBalancerIP), the cloud controller LISTS the public IPs in the group to find
# it, and listing is an RG-scope read. Selecting by name
# (service.beta.kubernetes.io/azure-pip-name) reads the IP directly and would allow
# a narrower scope -- worth tightening once the ingress chart uses the name.
resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
