# Static ingress IP, created OUTSIDE the MC_* node resource group so it survives
# cluster re-creation. The in-cluster ingress controller (platform/charts/traefik)
# binds its LoadBalancer Service to it:
#
#   annotations:
#     service.beta.kubernetes.io/azure-load-balancer-resource-group: rg-product-a-demo
#   spec:
#     loadBalancerIP: <this IP>
resource "azurerm_public_ip" "ingress" {
  name                = "pip-product-a-demo-ingress"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  sku                 = "Standard"
  allocation_method   = "Static"
  zones               = ["1"]

  # Recreating the IP changes the address: the wildcard DNS record and the
  # ingress loadBalancerIP value would silently point at nothing.
  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

# Dedicated static egress IP for the AKS managed load balancer. Unlike Azure's
# auto-created outbound IP, which lives in the MC_* resource group and is released
# when the cluster stops, this one is stable across stop/start and rebuilds, so
# the PostgreSQL firewall rule (postgres.tf) can trust it.
resource "azurerm_public_ip" "aks_outbound" {
  name                = "pip-product-a-demo-aks-outbound"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  sku                 = "Standard"
  allocation_method   = "Static"
  zones               = ["1"]

  tags = local.tags
}

# The AKS-managed load balancer must be allowed to attach IPs that live outside the
# node resource group. Without this the ingress Service sits in `Pending` forever,
# reporting no reason.
resource "azurerm_role_assignment" "aks_network_contributor" {
  scope                = azurerm_resource_group.demo.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# DNS for demo.product-a.example.net is served by an external DNS provider, not
# Azure, so there is no zone here. cert-manager solves ACME DNS-01 through that
# provider's API.
