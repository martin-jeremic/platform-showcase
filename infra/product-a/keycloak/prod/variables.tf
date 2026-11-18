variable "keycloak_url" {
  description = <<-EOT
    Keycloak base URL of the production instance. The `/keycloak` suffix is not
    optional: KC_HOSTNAME carries it, and Keycloak derives its relative path from
    that, so both the admin REST API and the discovery documents live under it.
  EOT
  type        = string
  default     = "https://app.product-a.example.net/keycloak"
}

variable "realm_name" {
  description = <<-EOT
    Realm slug: `product-a`, without an env suffix. The instance serves only
    production, and the platform charts already hard-code the issuer
    .../realms/product-a; Argo CD validates discovery against that exact string,
    so a mismatch here is a login failure, not a naming preference.
  EOT
  type        = string
  default     = "product-a"
}

variable "provisioner_client_secret" {
  description = "Secret of this realm's `terraform-provisioner` client. Export TF_VAR_provisioner_client_secret from kv-product-a-prod / terraform-provisioner--secret--clientSecret."
  type        = string
  sensitive   = true
}

variable "bootstrap_user_password" {
  description = <<-EOT
    One-time password for the bootstrap operator (platform-clients.tf). TEMPORARY in
    the Keycloak sense: a reset is forced at first login, and later applies never
    touch the credential again. Supply via TF_VAR_bootstrap_user_password. There is
    deliberately no default: a default would be a known password on the account
    that administers Argo CD.
  EOT
  type        = string
  sensitive   = true
}
