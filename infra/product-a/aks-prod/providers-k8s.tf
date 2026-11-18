# Helm provider, wired to the cluster this stack creates.
#
# Credentials come from the cluster's LOCAL ADMIN kubeconfig
# (azurerm_kubernetes_cluster.aks.kube_config). That is why this cluster keeps its
# local admin account enabled: local_account_disabled = true (Entra-only, as the
# org cluster runs) would remove exactly the credential this provider uses.
# Moving to Entra-only means kube_admin_config plus an exec-based kubelogin
# credential; listed in the README KNOWN-GAPS.
#
# `~> 3.0` is the current major of hashicorp/helm. Do not confuse it with the Helm
# CLI version: the provider embeds the Helm Go SDK and talks to the Kubernetes API
# itself, so the CLI on the machine running tofu has no bearing on what installs.
#
# v3 takes `kubernetes` as an ATTRIBUTE (`kubernetes = { ... }`); v2 took a nested
# block. Pinning back to ~> 2.x means changing this back to block syntax.
provider "helm" {
  kubernetes = {
    host                   = azurerm_kubernetes_cluster.aks.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate)
  }
}
