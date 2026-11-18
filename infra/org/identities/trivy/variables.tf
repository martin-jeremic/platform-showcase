variable "subscription_id" {
  description = "Platform subscription (cluster and registry are in it too). Null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "location" {
  description = "Region of the identity's metadata."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Own resource group, so no cluster stack's destroy can remove it."
  type        = string
  default     = "rg-org-trivy"
}

variable "identity_name" {
  description = "User-assigned identity the scan jobs act as."
  type        = string
  default     = "id-org-trivy-acr-pull"
}

variable "cluster_name" {
  description = "Cluster whose OIDC issuer the federation anchors to (read, not created)."
  type        = string
  default     = "aks-org-prod"
}

variable "cluster_resource_group_name" {
  description = "Resource group of the cluster (../../aks-prod)."
  type        = string
  default     = "rg-org-aks"
}

variable "trivy_namespace" {
  description = "Namespace of the Trivy operator. Part of the federated subject."
  type        = string
  default     = "trivy"
}

variable "trivy_service_account" {
  description = "ServiceAccount the scan jobs run as (the operator's own). Part of the federated subject."
  type        = string
  default     = "trivy-operator"
}

variable "acr_name" {
  description = "Registry the identity gets AcrPull on, and nothing else."
  type        = string
  default     = "orgacr"
}

variable "acr_resource_group_name" {
  description = "Resource group of the registry (../../registry)."
  type        = string
  default     = "rg-container-registry"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload    = "trivy"
    environment = "prod"
    managed_by  = "opentofu"
  }
}
