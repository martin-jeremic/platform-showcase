variable "subscription_id" {
  description = "Platform subscription. Null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "location" {
  description = "Region of the identity's metadata; an identity is global in use."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Own resource group, so no cluster stack's `tofu destroy` can remove the identity every GitOps sync depends on."
  type        = string
  default     = "rg-org-argocd"
}

variable "identity_name" {
  description = "User-assigned identity the hub's repo-server acts as towards Azure DevOps."
  type        = string
  default     = "id-argocd-hub-dev-git"
}

variable "oidc_issuer_url" {
  description = "The hub's ServiceAccount token issuer (platform/charts/oidc-issuer). Must equal, byte for byte, the FIRST --service-account-issuer flag of the hub's kube-apiserver: Entra compares it with the token's `iss` verbatim."
  type        = string
  default     = "https://dev.example.com/k8s-issuer"

  validation {
    condition     = startswith(var.oidc_issuer_url, "https://") && !endswith(var.oidc_issuer_url, "/")
    error_message = "oidc_issuer_url must start with https:// and have no trailing slash (the apiserver flag has none, and the comparison is verbatim)."
  }
}

variable "argocd_namespace" {
  description = "Namespace of the hub Argo CD. Part of the federated subject, compared verbatim."
  type        = string
  default     = "argocd-hub"
}

variable "repo_server_service_account" {
  description = "ServiceAccount of the repo-server (read from the live pod, not derived from the chart). Part of the subject."
  type        = string
  default     = "argocd-hub-repo-server"
}

variable "ado_org_url" {
  description = "Azure DevOps organisation the identity is added to."
  type        = string
  default     = "https://dev.azure.com/example-org"
}

variable "ado_projects" {
  description = "ADO projects whose repositories Argo CD reads; the identity joins each project's Readers group."
  type        = list(string)
  default     = ["platform", "product-a"]
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload    = "argocd"
    environment = "dev"
    managed_by  = "opentofu"
  }
}
