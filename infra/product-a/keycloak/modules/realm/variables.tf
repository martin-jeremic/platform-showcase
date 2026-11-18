variable "realm_name" {
  description = "Keycloak realm slug."
  type        = string
}

variable "env" {
  description = "Environment token composing the two env-specific client ids (product-a-audit-<env>, product-a-admin-api-<env>). Every other client id is the same in all realms."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "demo", "prod"], var.env)
    error_message = "env must be one of: dev, stage, demo, prod."
  }
}

variable "canonical_app_url" {
  description = "The single canonical SPA origin (root/base/admin URL and front-channel logout). Other hostnames go in app_redirect_uris / app_web_origins."
  type        = string
}

variable "app_redirect_uris" {
  description = "Valid redirect URIs of the SPA. A list because prod serves more than one hostname."
  type        = list(string)
}

variable "app_web_origins" {
  description = "CORS web origins of the SPA."
  type        = list(string)
}

variable "api_redirect_uris" {
  description = <<-EOT
    Valid redirect URIs of product-a-api. This list ALSO decides whether the client
    has the authorization-code flow at all: standard_flow_enabled = length(this) > 0.

    Derived because the two cannot disagree. A code flow with nowhere to send the
    code cannot complete a login, and the provider rejects that pair client-side on
    every create and update ("standard (authorization code) and implicit flows
    require at least one valid redirect uri").

    Greenfield realms pass their app URLs. The adopted dev realm passes nothing:
    its live client had the flow on with a single empty-string redirect URI, i.e. a
    login that could never complete, so it becomes the pure service-account client
    it effectively already was.
  EOT
  type        = list(string)
  default     = []
}

variable "api_realm_management_roles" {
  description = "realm-management client roles granted to product-a-api's service account. None by default: a root opts in explicitly, so the grant is visible to `tofu plan`."
  type        = list(string)
  default     = []
}

variable "admin_api_realm_management_roles" {
  description = "realm-management client roles granted to the admin API's service account, which calls the Keycloak admin REST API."
  type        = list(string)
  default     = []
}

variable "registration_allowed" {
  description = <<-EOT
    Whether users may create their own accounts on the login page.

    Defaults to true because that is what the live dev realm has, and this module is
    a drift detector before it is a policy: a false default would make dev plan a
    change nobody asked for. Prod sets it false explicitly: its login page is public
    and fronts Argo CD and Grafana, so open self-registration would let anyone mint
    an account in that realm.
  EOT
  type        = bool
  default     = true
}

variable "manage_realm" {
  description = "Whether this module owns keycloak_realm. False while adopting an existing realm (it resets undeclared attributes, so it is adopted LAST); greenfield realms start true."
  type        = bool
  default     = false
}
