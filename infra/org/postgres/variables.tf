variable "subscription_id" {
  description = "Platform subscription. Null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "swedencentral"
}

variable "resource_group_name" {
  description = "Resource group of the server."
  type        = string
  default     = "rg-org-postgres"
}

variable "server_name" {
  description = "PostgreSQL Flexible Server name (globally unique, lowercase)."
  type        = string
  default     = "psql-org"
}

variable "postgres_version" {
  description = "Major version."
  type        = string
  default     = "16"
}

variable "sku_name" {
  description = "Compute SKU. B1ms = 1 vCore / 2 GiB."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "storage_mb" {
  description = "Storage in MB."
  type        = number
  default     = 32768
}

variable "storage_auto_grow_enabled" {
  description = "Storage auto-grow."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Server backup retention (7-35)."
  type        = number
  default     = 7
}

variable "geo_redundant_backup_enabled" {
  description = "Geo-redundant backups. Immutable after create."
  type        = bool
  default     = false
}

variable "administrator_login" {
  description = "Administrator login."
  type        = string
  default     = "pgadmin"
}

variable "administrator_password" {
  description = "Administrator password. TF_VAR_administrator_password, read from the vault (postgres--admin--password). Never committed."
  type        = string
  sensitive   = true
}

# Note: one database on the live server has a DOTTED name. ARM rejects dotted
# database names (400 InvalidParameterValue), so the provider can neither import
# nor read it; it was created with SQL and stays managed outside OpenTofu.
variable "databases" {
  description = "Databases on the server (UTF8 / en_US.utf8)."
  type        = set(string)
  default = [
    "product_a",
    "product_a_audit_logs",
    "backstage",
    "payments",
    "payments_email",
    "payments_invoicing",
  ]
}

# The committed default IS the live allow-list (rule names kept verbatim: renaming
# replaces the rule, and portal-generated names are live names like any other).
# An empty default here was once the one drift finding in the repo: a clean checkout
# planned to destroy live rules and cut off whoever was behind them. Override only
# with the FULL map plus your entry.
variable "firewall_rules" {
  description = "Server firewall allow-list: name => { start_ip_address, end_ip_address }."
  type = map(object({
    start_ip_address = string
    end_ip_address   = string
  }))
  default = {
    "aks-org-prod-egress"                = { start_ip_address = "192.0.2.40", end_ip_address = "192.0.2.40" }
    "office"                             = { start_ip_address = "203.0.113.10", end_ip_address = "203.0.113.10" }
    "ClientIPAddress_2025-1-15_10-12-33" = { start_ip_address = "198.51.100.23", end_ip_address = "198.51.100.23" }
  }

  validation {
    condition     = alltrue([for r in values(var.firewall_rules) : can(cidrhost("${r.start_ip_address}/32", 0)) && can(cidrhost("${r.end_ip_address}/32", 0))])
    error_message = "start_ip_address and end_ip_address must be IPv4 addresses."
  }
}

variable "allowed_extensions" {
  description = "Extensions allow-listed in azure.extensions (uppercase). APPEND, never replace: the resource owns the whole parameter."
  type        = list(string)
  default     = ["PGCRYPTO", "PG_TRGM", "UNACCENT"]
}

# Raised from the Burstable default. Each backend costs real memory on a 2 GiB
# server, and built-in PgBouncer is unavailable on Burstable: pool in the app
# before raising this further.
variable "max_connections" {
  description = "max_connections (static: needs a server restart to take effect)."
  type        = number
  default     = 150
}

variable "app_key_vault_name" {
  description = "Vault the application role passwords are written to (app-roles.tf)."
  type        = string
  default     = "kv-org-dev"
}

variable "app_key_vault_resource_group_name" {
  description = "Resource group of app_key_vault_name (../keyvaults)."
  type        = string
  default     = "rg-keyvaults"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload    = "postgres"
    environment = "prod"
    managed_by  = "opentofu"
  }
}
