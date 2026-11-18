terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }

    # Roles and grants INSIDE the server (app-roles.tf). ARM manages databases and
    # server parameters, not what lives in them.
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.25"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "org-postgres.tfstate"
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}

# Talks to the server itself, through its public endpoint, as the administrator:
# the applier's IP must be in var.firewall_rules. Azure's administrator is not a
# superuser (it is a member of azure_pg_admin), hence superuser = false; it may
# create roles and grant on databases it owns.
#
# This is the trade-off product-a's stack declined (../../product-a/aks-prod/
# postgres.tf): a network path from the applier, and role passwords in state. Here
# the server is shared, the applier set is small and fixed, and the password goes
# straight into Key Vault in the same apply -- so nobody types it into psql.
provider "postgresql" {
  host            = azurerm_postgresql_flexible_server.pg.fqdn
  port            = 5432
  database        = "postgres"
  username        = var.administrator_login
  password        = var.administrator_password
  sslmode         = "require"
  superuser       = false
  connect_timeout = 15
}
