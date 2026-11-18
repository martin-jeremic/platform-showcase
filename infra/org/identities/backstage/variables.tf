variable "subscription_id" {
  description = "Platform subscription. Null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "location" {
  description = "Region of the identity's metadata."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Own resource group, so no other stack's destroy can remove the identity the portal depends on."
  type        = string
  default     = "rg-org-backstage"
}

variable "identity_name" {
  description = "User-assigned identity the portal pod acts as."
  type        = string
  default     = "id-org-backstage-dev"
}

variable "oidc_issuer_url" {
  description = "The hub's ServiceAccount token issuer; byte-for-byte equal to the first --service-account-issuer flag."
  type        = string
  default     = "https://dev.example.com/k8s-issuer"

  validation {
    condition     = startswith(var.oidc_issuer_url, "https://") && !endswith(var.oidc_issuer_url, "/")
    error_message = "oidc_issuer_url must start with https:// and have no trailing slash."
  }
}

variable "backstage_namespace" {
  description = "Namespace of the portal on the hub. Part of the federated subject."
  type        = string
  default     = "backstage"
}

variable "backstage_service_account" {
  description = "ServiceAccount of the portal pod. Part of the federated subject."
  type        = string
  default     = "backstage"
}

variable "ado_org_url" {
  description = "Azure DevOps organisation."
  type        = string
  default     = "https://dev.azure.com/example-org"
}

variable "ado_read_projects" {
  description = "Projects whose repositories carry catalog descriptors (Readers)."
  type        = list(string)
  default     = ["platform", "product-a"]
}

variable "ado_write_projects" {
  description = "Projects the software templates write to (Contributors)."
  type        = list(string)
  default     = ["platform"]
}

variable "key_vaults" {
  description = "Vaults the portal mounts backstage--* secrets from."
  type        = list(string)
  default     = ["kv-org-dev"]
}

variable "key_vault_resource_group_name" {
  description = "Resource group of the vaults (../../keyvaults)."
  type        = string
  default     = "rg-keyvaults"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload    = "backstage"
    environment = "dev"
    managed_by  = "opentofu"
  }
}
