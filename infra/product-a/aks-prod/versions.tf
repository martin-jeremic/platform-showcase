terraform {
  # 1.9+ for cross-variable references in validation blocks (variables.tf).
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    # Installs Argo CD (argocd.tf). v3 changed the provider's kubernetes config from
    # a nested block to an attribute; see providers-k8s.tf.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstateexample"
    container_name       = "tfstate"
    key                  = "product-a-prod.tfstate"
  }
}
