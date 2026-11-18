variable "subscription_id" {
  description = "Subscription to deploy into. Null uses ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Resource group for the Foundry resources."
  type        = string
  default     = "rg-product-a-ai"
}

variable "foundry_account_name" {
  description = "Name (and custom subdomain) of the AIServices account. Globally unique."
  type        = string
  default     = "foundry-product-a"
}

variable "project_name" {
  description = "Foundry project name."
  type        = string
  default     = "product-a"
}

variable "project_display_name" {
  description = "Foundry project display name."
  type        = string
  default     = "Product A"
}

variable "model_name" {
  description = "Model to deploy."
  type        = string
  default     = "gpt-5-mini"
}

variable "model_format" {
  description = "Model publisher/format."
  type        = string
  default     = "OpenAI"
}

variable "model_version" {
  description = "Model version. Null lets Azure pick the default available version."
  type        = string
  default     = null
}

variable "deployment_name" {
  description = "Deployment name; what callers pass as the model/deployment."
  type        = string
  default     = "llm-product-a"
}

variable "deployment_sku_name" {
  description = "Deployment SKU (GlobalStandard, Standard, DataZoneStandard)."
  type        = string
  default     = "GlobalStandard"
}

variable "deployment_capacity" {
  description = "Capacity in thousands of tokens per minute."
  type        = number
  default     = 10
}

variable "local_auth_enabled" {
  description = "Allow API-key authentication on the account. Set false once every caller uses Entra tokens (workload identity + Cognitive Services OpenAI User)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    project    = "product-a"
    workload   = "ai"
    managed_by = "opentofu"
  }
}
