variable "subscription_id" {
  description = "Platform subscription. Null uses ARM_SUBSCRIPTION_ID (pin it: rule 10 of the import methodology)."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "swedencentral"
}

# Deviates from the repo's `rg-org-<workload>` convention. The group was created by
# hand under this name and renaming it is destroy-and-recreate, so the LIVE name
# wins. Rule 1: import, don't rebuild.
variable "resource_group_name" {
  description = "Existing resource group of the SQL server."
  type        = string
  default     = "rg-sql-org"
}

# Likewise without the env token. Renaming a logical server changes its FQDN and
# needs a data migration.
variable "server_name" {
  description = "Existing Azure SQL logical server."
  type        = string
  default     = "sql-org"
}

variable "administrator_login" {
  description = "SQL administrator login (live value)."
  type        = string
  default     = "sqladmin"
}

variable "administrator_login_password" {
  description = <<-EOT
    SQL administrator password. WRITE-ONLY: Azure never returns it, so import
    cannot read the current value and OpenTofu cannot detect drift on it.

    The provider requires one of administrator_login_password /
    administrator_login_password_wo / azuread_authentication_only, so it cannot be
    omitted. It is required here but held INERT by ignore_changes on the server:
    whatever is passed is not pushed to Azure. Any placeholder satisfies it today.

    At go-live: set the real value, remove the ignore_changes entry, apply -- that
    rotates the password. Supply via TF_VAR_administrator_login_password.
  EOT
  type        = string
  sensitive   = true
}

variable "collation" {
  description = "Collation shared by all databases."
  type        = string
  default     = "SQL_Latin1_General_CP1_CI_AS"
}

variable "databases" {
  description = "User databases (`master` is a system DB and excluded)."
  type = map(object({
    sku_name                 = string
    max_size_gb              = number
    storage_account_type     = string
    retention_days           = number
    backup_interval_in_hours = number
  }))
  default = {
    # Imported. The two naming styles are live names kept verbatim: a rename is
    # ForceNew, i.e. a destroy-and-create of the data.
    "Org.I18n"     = { sku_name = "Basic", max_size_gb = 2, storage_account_type = "Local", retention_days = 7, backup_interval_in_hours = 12 }
    "Org.Access"   = { sku_name = "Basic", max_size_gb = 2, storage_account_type = "Local", retention_days = 7, backup_interval_in_hours = 12 }
    "keycloak"     = { sku_name = "Basic", max_size_gb = 2, storage_account_type = "Local", retention_days = 7, backup_interval_in_hours = 24 }
    "keycloak-dev" = { sku_name = "Basic", max_size_gb = 2, storage_account_type = "Local", retention_days = 7, backup_interval_in_hours = 24 }

    # The first databases CREATED (not imported) here belong to the legacy-app
    # migration, which is paused. Named snake_case on purpose: dots and mixed case
    # leak into connection strings and shell quoting, and a rename after go-live is
    # a data migration. Off until the migration resumes, like the node pool in
    # ../aks-prod/nodepools.tf:
    # "legacy_app_core" = { sku_name = "S0", max_size_gb = 10, storage_account_type = "Local", retention_days = 7, backup_interval_in_hours = 12 }
  }
}

# Unlike most allow-lists this must NOT default to {}: rules exist live, and an
# empty default would plan their destruction.
variable "firewall_rules" {
  description = "Server firewall allow-list, imported from the live server."
  type = map(object({
    start_ip_address = string
    end_ip_address   = string
  }))
  default = {
    # The portal's "Allow Azure services and resources to access this server".
    "AllowAllWindowsAzureIps" = { start_ip_address = "0.0.0.0", end_ip_address = "0.0.0.0" }
    # Portal-generated name, kept verbatim: renaming would destroy and recreate it.
    "ClientIPAddress_2025-9-30_10-49-21" = { start_ip_address = "198.51.100.23", end_ip_address = "198.51.100.23" }
  }
}

# The import ran with this EMPTY so the post-import plan could say "No changes";
# a tag diff on every resource would have hidden a real mistake among expected
# ones. The standard map landed in the second commit.
variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload    = "mssql"
    environment = "prod"
    managed_by  = "opentofu"
  }
}
