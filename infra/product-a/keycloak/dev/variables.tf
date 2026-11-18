variable "keycloak_url" {
  description = "Keycloak base URL (including the relative path). Dev, stage and demo realms share the hub instance."
  type        = string
  default     = "https://dev.example.com/keycloak"
}

variable "realm_name" {
  description = "Realm slug."
  type        = string
  default     = "product-a-dev"
}

variable "provisioner_client_secret" {
  description = "Secret of this realm's `terraform-provisioner` client. Never committed: export TF_VAR_provisioner_client_secret, read from kv-product-a-dev / terraform-provisioner--secret--clientSecret."
  type        = string
  sensitive   = true
}
