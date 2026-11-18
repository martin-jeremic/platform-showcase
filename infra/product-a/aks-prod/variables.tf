# --- Subscriptions and region --------------------------------------------------

variable "subscription_id" {
  description = "Subscription hosting the cluster. Null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "shared_subscription_id" {
  description = "Shared-services subscription holding the registries and the per-environment Key Vaults."
  type        = string
  default     = "22222222-2222-2222-2222-222222222222"
}

variable "location" {
  description = "Azure region for every resource. Prod is single-region."
  type        = string
  default     = "westeurope"
}

# --- Cluster shape -------------------------------------------------------------

variable "shape" {
  description = "Cluster shape: \"A\" = four node pools (physical isolation), \"B\" = one system node."
  type        = string
  default     = "A"

  validation {
    condition     = contains(["A", "B"], var.shape)
    error_message = "shape must be \"A\" or \"B\"."
  }
}

variable "ephemeral_os" {
  description = "Use d-suffix SKUs with ephemeral OS disks; false falls back to s-suffix SKUs with managed disks."
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "AKS minor alias (\"1.37\"), never a patch. Single source of truth: set here, not in a git-ignored tfvars, so the version prod runs is in git. Raise one minor per apply."
  type        = string
  default     = "1.37"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor alias such as \"1.37\", not a patch version."
  }
}

variable "api_server_authorized_ip_ranges" {
  description = "CIDRs allowed to reach the Kubernetes API server. Must include the egress of whatever runs tofu (and the CI agents), or the next apply locks itself out."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.api_server_authorized_ip_ranges : can(cidrhost(c, 0))])
    error_message = "Each entry must be a CIDR, e.g. 198.51.100.0/24 or 203.0.113.7/32."
  }

  # Private by default: an empty list means "open to the internet", so it is only
  # accepted together with an explicit opt-in.
  validation {
    condition     = length(var.api_server_authorized_ip_ranges) > 0 || var.allow_public_api_server
    error_message = "api_server_authorized_ip_ranges is empty, which leaves the API server open to the internet. Set authorized ranges, or set allow_public_api_server = true to accept that deliberately."
  }
}

variable "allow_public_api_server" {
  description = "Explicit opt-in to an API server with no IP restriction (still Entra/cert authenticated). Only meaningful when api_server_authorized_ip_ranges is empty."
  type        = bool
  default     = false
}

# --- HA seam -------------------------------------------------------------------
# var.ha drives only settings that can change on a LIVE environment. Anything
# immutable at create time has its own variable below, defaulted to the prod-safe
# value now, because getting those wrong is expensive to undo.

variable "ha" {
  description = "Real HA posture: Standard AKS tier (uptime SLA), higher pool floors, SameZone PostgreSQL HA, hard pod anti-affinity for Argo CD. All in-place changes. Requires a non-Burstable pg_sku."
  type        = bool
  default     = false
}

variable "node_zones" {
  description = "Availability zones for the node pools. NOT gated on var.ha: changing a pool's zones REPLACES the pool. Single zone because only one zone had capacity for the chosen VM family in this subscription; widening it needs a different SKU family, region or subscription, not a longer list."
  type        = list(string)
  default     = ["2"]
}

variable "pg_zone" {
  description = "Zone of the PostgreSQL primary. Keep equal to the node zone. Immutable."
  type        = string
  default     = "2"
}

variable "public_ip_zones" {
  description = "Zones for the static ingress and egress IPs. Zone-redundant and independent of node_zones: same price, and changing it later replaces the IP (and therefore the address)."
  type        = list(string)
  default     = ["1", "2", "3"]
}

# --- Networking (bring-your-own VNet, see network.tf) ---------------------------

variable "vnet_address_space" {
  description = "Address space of the VNet. Far from Azure's managed-AKS default (10.224.0.0/12) so a future peering does not collide."
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_nodes_cidr" {
  description = "Subnet for nodes and internal load balancers. With CNI Overlay, pods do not consume addresses here."
  type        = string
  default     = "10.10.0.0/22"
}

variable "subnet_privatelink_cidr" {
  description = "Subnet reserved for Private Endpoints (created empty)."
  type        = string
  default     = "10.10.4.0/24"
}

variable "pod_cidr" {
  description = "Overlay pod CIDR. Not routed in the VNet; must not overlap it."
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes service CIDR; must overlap neither the VNet nor the pod CIDR."
  type        = string
  default     = "10.11.0.0/16"
}

variable "dns_service_ip" {
  description = "Cluster DNS service address, inside service_cidr."
  type        = string
  default     = "10.11.0.10"
}

# --- PostgreSQL ----------------------------------------------------------------

variable "pg_sku" {
  description = "PostgreSQL SKU. Burstable is fine pre-launch; HA needs General Purpose or Memory Optimized. A precondition blocks ha = true with a B_* SKU."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "pg_storage_mb" {
  description = "Storage in MB. Grows in place, never shrinks."
  type        = number
  default     = 32768
}

variable "pg_admin_login" {
  description = "PostgreSQL administrator login."
  type        = string
  default     = "pgadmin"
}

variable "pg_backup_retention_days" {
  description = "Server-side backup retention (7-35). Dies with the server; backup.tf adds the independent vaulted copy."
  type        = number
  default     = 35
}

variable "pg_geo_redundant_backup" {
  description = "Replicate server backups to the paired region. IMMUTABLE after create."
  type        = bool
  default     = true
}

variable "pg_entra_admin_object_id" {
  description = "Object ID of an Entra user or group to make PostgreSQL administrator. Null disables it."
  type        = string
  default     = null
}

variable "pg_entra_admin_principal_name" {
  description = "UPN (user) or display name (group) matching pg_entra_admin_object_id."
  type        = string
  default     = null
}

variable "pg_entra_admin_principal_type" {
  description = "Principal type of the Entra PostgreSQL administrator."
  type        = string
  default     = "Group"

  validation {
    condition     = contains(["User", "Group", "ServicePrincipal"], var.pg_entra_admin_principal_type)
    error_message = "pg_entra_admin_principal_type must be User, Group or ServicePrincipal."
  }
}

variable "pg_admin_client_ips" {
  description = "Map of label => public IPv4 allowed to reach PostgreSQL directly. Keep empty in committed config."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for ip in values(var.pg_admin_client_ips) : can(cidrhost("${ip}/32", 0))])
    error_message = "Each value must be a single IPv4 address (no CIDR suffix)."
  }
}

# --- Storage -------------------------------------------------------------------

variable "storage_account_name" {
  description = "Globally unique storage account name."
  type        = string
  default     = "stproductaprod"
}

variable "storage_replication_type" {
  description = "Storage redundancy. Immutable in practice (LRS<->ZRS needs a migration)."
  type        = string
  default     = "ZRS"
}

variable "storage_shared_key_enabled" {
  description = "Allow account-key access. Off: every consumer uses Entra (workload identity, trusted services)."
  type        = bool
  default     = false
}

variable "observability_retention_days" {
  description = "Lifecycle deletion age for Loki chunks and Tempo traces. Keep >= the chart's retention_period."
  type        = number
  default     = 31
}

# --- Backup --------------------------------------------------------------------

variable "backup_vault_redundancy" {
  description = "Data Protection vault redundancy. IMMUTABLE after create."
  type        = string
  default     = "GeoRedundant"
}

variable "blob_backup_retention_days" {
  description = "Operational blob backup retention, shared with the account's restore policy (soft delete is this + 1)."
  type        = number
  default     = 30
}

variable "pg_weekly_retention" {
  description = "Retention of every weekly vaulted PostgreSQL backup (ISO 8601)."
  type        = string
  default     = "P12W"
}

variable "pg_monthly_retention" {
  description = "Retention of the first backup of each month (ISO 8601)."
  type        = string
  default     = "P12M"
}

variable "pg_yearly_retention" {
  description = "Retention of the first backup of each year (ISO 8601)."
  type        = string
  default     = "P7Y"
}

# --- Diagnostics ---------------------------------------------------------------

variable "aks_diagnostic_log_categories" {
  description = "AKS control-plane log categories archived to blob."
  type        = list(string)
  default     = ["kube-audit-admin", "kube-apiserver", "kube-controller-manager", "cluster-autoscaler"]
}

variable "pg_diagnostic_log_categories" {
  description = "PostgreSQL log categories archived to blob."
  type        = list(string)
  default     = ["PostgreSQLLogs"]
}

# --- Shared registries and vault -------------------------------------------------

variable "enable_key_vault_access" {
  description = "Look up the per-env vault, grant the kubelet identity Key Vault Secrets User, and write the PG admin password into it. A data source on a vault that does not exist is a hard plan failure, hence the gate."
  type        = bool
  default     = false
}

variable "acr_name" {
  description = "Application registry the kubelet identity pulls from."
  type        = string
  default     = "productacr"
}

variable "acr_resource_group_name" {
  description = "Resource group of the registries."
  type        = string
  default     = "rg-container-registry"
}

variable "additional_acr_names" {
  description = "Further registries (same RG and subscription) the kubelet identity needs AcrPull on. AcrPull is per registry."
  type        = set(string)
  default     = ["orgacr"]
}

variable "key_vault_name" {
  description = "Per-environment Key Vault."
  type        = string
  default     = "kv-product-a-prod"
}

variable "key_vault_resource_group_name" {
  description = "Resource group of the per-environment Key Vaults."
  type        = string
  default     = "rg-keyvaults"
}

# --- Argo CD -------------------------------------------------------------------

variable "argocd_namespace" {
  description = "Namespace Argo CD is installed into."
  type        = string
  default     = "argocd"
}

variable "argocd_release_name" {
  description = "Helm release name AND fullnameOverride. Must equal the wrapper chart's releaseName/fullnameOverride, or wave 5 installs a second Argo CD (argocd.tf)."
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "argo-cd chart version. MUST equal the argo-cd dependency pinned in the wrapper chart. Only governs a fresh bootstrap; on a live cluster the release is frozen and Argo CD upgrades itself."
  type        = string
  default     = "10.11.6" # = platform/charts/argocd Chart.yaml dependency (Argo CD v3.5.6)
}

variable "argocd_install_timeout" {
  description = "Seconds helm_release waits for Argo CD to converge (first install may wait on the autoscaler)."
  type        = number
  default     = 1800
}
