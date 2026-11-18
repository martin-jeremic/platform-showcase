#!/usr/bin/env python3
"""kc_export.py - read-only: live Keycloak realm -> realm-<slug>.tf + imports-<slug>.tf

Reads ONE realm through the admin REST API (GET only, plus the token request) and
writes two files into an infra/org/keycloak root:

  realm-<slug>.tf    `module "<slug>" { source = "../modules/realm" ... }` with every
                     managed object, values verbatim;
  imports-<slug>.tf  one import block per importable resource type, with the live
                     UUIDs / aliases, addressed into the module. TEMPORARY: delete it
                     after the adoption apply.

Fidelity rules, all learned the hard way in earlier stacks:
  * never `partial-export`: it omits default-valued mapper config and every
    execution id. Everything comes from the per-object admin endpoints;
  * built-in and auto-created objects are filtered by explicit lists;
  * durations are converted to the provider's Go format; fields the provider
    computes are omitted where live is empty;
  * secrets are never written. Client secrets are not even read; broker secrets
    arrive masked and the module handles the mask;
  * live state the module cannot express without CHANGING it on apply (composite
    client roles, composites of built-ins) stops the export instead of being
    silently flattened.

Re-running after the adoption apply must produce no git diff, which makes the
exporter a drift audit independent of `tofu plan`. Generated files therefore carry
only generated comments; explanations belong in docs/keycloak-consolidation.md.

Showcase trim: organisations, user profile, events and required actions are
omitted, matching the trimmed module. Standard library only.

USAGE
  # first run, before the provisioner exists: a human admin in master
  python kc_export.py --url https://services.example.com --realm org \\
      --admin-user <admin> --out ../../org/keycloak/services
  # afterwards: the stack's own credential, secret from $KC_PROVISIONER_SECRET
  python kc_export.py --url https://services.example.com --realm org --out ../../org/keycloak/services

The admin password comes from $KC_ADMIN_PASSWORD or a prompt, never from argv.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter, defaultdict

from kc_admin import KeycloakAdmin, log, resolve_secret

# --- What is deliberately NOT managed --------------------------------------------

BUILTIN_CLIENTS = {
    "account", "account-console", "admin-cli", "broker", "realm-management",
    "security-admin-console", "admin-permissions",
}
PROVISIONER_CLIENT_IDS = {"tofu-provisioner", "terraform-provisioner"}
BUILTIN_CLIENT_SCOPES = {
    "acr", "address", "basic", "email", "microprofile-jwt", "offline_access",
    "organization", "phone", "profile", "role_list", "roles", "saml_organization",
    "service_account", "web-origins", "AuthnContextClassRef",
}
BUILTIN_REALM_ROLES = {"offline_access", "uma_authorization"}
AUTO_CLIENT_ROLES = {"uma_protection"}

# Realm attributes carried in settings.attributes. Everything else either
# duplicates a first-class argument (managed twice) or is Keycloak-internal.
REALM_ATTRIBUTE_ALLOWLIST = ("frontendUrl", "acr.loa.map", "parRequestUriLifespan")

# Client attributes with a first-class provider argument. Any of these in
# extra_config is REJECTED by the provider, so they are mapped instead.
CLIENT_FIRST_CLASS_ATTRIBUTES = {
    "pkce.code.challenge.method", "post.logout.redirect.uris", "use.refresh.tokens",
    "display.on.consent.screen", "consent.screen.text", "login_theme",
    "backchannel.logout.url", "frontchannel.logout.url",
    "backchannel.logout.session.required", "backchannel.logout.revoke.offline.tokens",
    "access.token.lifespan", "client.session.idle.timeout", "client.session.max.lifespan",
    "client.offline.session.idle.timeout", "client.offline.session.max.lifespan",
    "client_credentials.use_refresh_token", "dpop.bound.access.tokens",
    "exclude.session.state.from.auth.response", "exclude.issuer.from.auth.response",
    "oauth2.device.authorization.grant.enabled", "standard.token.exchange.enabled",
}
CLIENT_NOISE_ATTRIBUTES = {"client.secret.creation.time", "realm_client"}
CLIENT_NOISE_PREFIXES = ("saml.", "saml_")

IDP_FIRST_CLASS_CONFIG = {
    "clientId", "clientSecret", "authorizationUrl", "tokenUrl", "userInfoUrl", "jwksUrl",
    "logoutUrl", "issuer", "defaultScope", "tenantId", "prompt", "syncMode", "guiOrder",
    "backchannelSupported", "validateSignature", "useJwksUrl", "disableUserInfo",
    "hideOnLoginPage", "acceptsPromptNoneForwardFromClient", "uiLocales", "loginHint",
}

# Keycloak's GroupMembershipMapper writes multivalued=true into the CACHED model on
# every token it issues and never stores it, so the admin API returns the key only
# if someone logged in since the last cache reload. Always declare it: omitted, a
# login would put it back and the plan would flip-flop with login activity.
RUNTIME_ENFORCED_MAPPER_CONFIG = {"oidc-group-membership-mapper": {"multivalued": "true"}}

# Values equal to the module default are left out so what remains is what
# distinguishes an object. *_ALWAYS keys define the object's nature.
CLIENT_DEFAULTS = {
    "name": "", "description": "", "enabled": True, "client_authenticator_type": "client-secret",
    "implicit_flow_enabled": False, "root_url": "", "base_url": "", "admin_url": "",
    "full_scope_allowed": True, "consent_required": False, "display_on_consent_screen": False,
    "always_display_in_console": False, "frontchannel_logout_enabled": True,
    "backchannel_logout_session_required": True, "backchannel_logout_revoke_offline_sessions": False,
    "use_refresh_tokens": True, "use_refresh_tokens_client_credentials": False,
}
CLIENT_ALWAYS = {"access_type", "standard_flow_enabled", "direct_access_grants_enabled", "service_accounts_enabled"}
SCOPE_DEFAULTS = {"description": "", "include_in_token_scope": True, "include_in_openid_provider_metadata": True}

FLOW_BINDINGS = (
    ("browserFlow", "browser_flow"), ("registrationFlow", "registration_flow"),
    ("directGrantFlow", "direct_grant_flow"), ("resetCredentialsFlow", "reset_credentials_flow"),
    ("clientAuthenticationFlow", "client_authentication_flow"),
    ("dockerAuthenticationFlow", "docker_authentication_flow"),
    ("firstBrokerLoginFlow", "first_broker_login_flow"),
)
MULTIVALUE_SEPARATOR = "##"


def mapper_config(mapper: dict) -> dict:
    config = dict(mapper.get("config") or {})
    config.update(RUNTIME_ENFORCED_MAPPER_CONFIG.get(mapper.get("protocolMapper"), {}))
    return dict(sorted(config.items()))


def strip_defaults(entry: dict, defaults: dict, always: set) -> dict:
    return {k: v for k, v in entry.items() if k in always or k not in defaults or v != defaults[k]}


# --- HCL rendering ------------------------------------------------------------------

IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")


class Note:
    """A value with comment lines rendered above its `key = value` line."""

    def __init__(self, value, *comments: str):
        self.value = value
        self.comments = [c for c in comments if c]


def hcl_string(text: str) -> str:
    escaped = (text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
               .replace("\t", "\\t").replace("${", "$${").replace("%{", "%%{"))
    return f'"{escaped}"'


def hcl_key(key: str) -> str:
    return key if IDENTIFIER.match(key) else hcl_string(key)


def render_value(value, indent: str) -> str:
    if isinstance(value, Note):
        value = value.value
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return hcl_string(value)
    inner = indent + "  "
    if isinstance(value, (list, tuple, set)):
        items = list(value)
        if not items:
            return "[]"
        rendered = [render_value(item, inner) for item in items]
        if all(not isinstance(i, (dict, list)) for i in items) and sum(len(r) + 2 for r in rendered) <= 96:
            return "[" + ", ".join(rendered) + "]"
        return "[\n" + "".join(f"{inner}{r},\n" for r in rendered) + f"{indent}]"
    if isinstance(value, dict):
        entries = render_entries(value, inner)
        return "{\n" + "".join(f"{line}\n" for line in entries) + f"{indent}}}" if entries else "{}"
    raise TypeError(f"cannot render {type(value).__name__}")


def render_entries(mapping: dict, indent: str) -> list[str]:
    lines: list[str] = []
    for key, value in mapping.items():
        plain = value.value if isinstance(value, Note) else value
        if plain is None:
            continue
        for comment in value.comments if isinstance(value, Note) else []:
            lines.append(f"{indent}# {comment}")
        lines.append(f"{indent}{hcl_key(key)} = {render_value(plain, indent)}")
    return lines


def sorted_map(mapping: dict) -> dict:
    return {k: mapping[k] for k in sorted(mapping, key=lambda s: (s.lower(), s))}


def duration(seconds) -> str | None:
    """Seconds -> Go duration ("30m", "10h", "1h30m", "0s")."""
    if seconds is None:
        return None
    total = int(seconds)
    if total == 0:
        return "0s"
    hours, rest = divmod(total, 3600)
    minutes, secs = divmod(rest, 60)
    return (f"{hours}h" if hours else "") + (f"{minutes}m" if minutes else "") + (f"{secs}s" if secs else "")


def bool_quoted(attributes: dict, key: str, default: bool = False) -> bool:
    """Keycloak stores booleans as "true"/"false" strings; absence reads as `default`."""
    value = attributes.get(key)
    if value in (None, ""):
        return default
    return value if isinstance(value, bool) else str(value).lower() == "true"


def non_empty(value):
    return value if value not in (None, "") else None


def join_multivalue(attributes) -> dict | None:
    if not attributes:
        return None
    return {k: MULTIVALUE_SEPARATOR.join(map(str, v)) if isinstance(v, list) else str(v) for k, v in sorted(attributes.items())}


def slugify(realm: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", realm.lower()).strip("-")


# --- The exporter ---------------------------------------------------------------------

class RealmExporter:
    def __init__(self, admin: KeycloakAdmin, realm: str):
        self.admin = admin
        self.realm = realm
        self.warnings: list[str] = []
        self.imports: dict[str, dict[str, str]] = defaultdict(dict)  # resource -> {key: id suffix}
        self.creates: Counter = Counter()
        self.changes: Counter = Counter({"keycloak_realm.this": 1})  # deletion-protection flip
        self.missing_refresh_tokens: list[str] = []

    def get(self, path: str, params: dict | None = None):
        return self.admin.get(f"/realms/{self.realm}{path}", params)

    def get_all(self, path: str, params: dict | None = None):
        return self.admin.get_all(f"/realms/{self.realm}{path}", params)

    def warn(self, message: str) -> None:
        self.warnings.append(message)
        log(f"WARNING: {message}")

    @staticmethod
    def fail(message: str) -> None:
        raise SystemExit(f"ERROR: {message}")

    def export(self) -> dict:
        realm = self.get("")
        if realm is None:
            raise SystemExit(f"Realm '{self.realm}' does not exist.")
        all_clients = self.get_all("/clients")
        self.client_id_by_uuid = {c["id"]: c["clientId"] for c in all_clients}
        all_flows = self.get("/authentication/flows") or []
        self.flow_alias_by_id = {f["id"]: f["alias"] for f in all_flows}

        default_scopes = sorted(s["name"] for s in self.get("/default-default-client-scopes") or [])
        optional_scopes = sorted(s["name"] for s in self.get("/default-optional-client-scopes") or [])
        self.imports["keycloak_realm_default_client_scopes.this[0]"][""] = self.realm
        self.imports["keycloak_realm_optional_client_scopes.this[0]"][""] = self.realm

        clients = self.export_clients(all_clients)
        identity_providers = self.export_identity_providers()
        flows, subflows, executions = self.export_flows(all_flows, realm)
        self.imports["keycloak_realm.this"][""] = self.realm
        return {
            "realm": self.realm,
            "settings": self.export_settings(realm),
            "default_client_scopes": default_scopes,
            "optional_client_scopes": optional_scopes,
            "default_roles": self.export_default_roles(realm),
            "client_scopes": self.export_client_scopes(),
            "roles": self.export_realm_roles(realm),
            "groups": self.export_groups(),
            "clients": clients,
            "identity_providers": identity_providers,
            "authentication_flows": flows,
            "authentication_subflows": subflows,
            "authentication_executions": executions,
        }

    # --- realm settings -------------------------------------------------------------

    def export_settings(self, r: dict) -> dict:
        headers = r.get("browserSecurityHeaders") or {}
        attributes = r.get("attributes") or {}
        settings = {
            "enabled": r.get("enabled", True),
            "display_name": r.get("displayName", ""),
            "registration_allowed": r.get("registrationAllowed", False),
            "registration_email_as_username": r.get("registrationEmailAsUsername", False),
            "edit_username_allowed": r.get("editUsernameAllowed", False),
            "reset_password_allowed": r.get("resetPasswordAllowed", False),
            "remember_me": r.get("rememberMe", False),
            "verify_email": r.get("verifyEmail", False),
            "login_with_email_allowed": r.get("loginWithEmailAllowed", True),
            "duplicate_emails_allowed": r.get("duplicateEmailsAllowed", False),
            "ssl_required": r.get("sslRequired", "external"),
            "default_signature_algorithm": r.get("defaultSignatureAlgorithm"),
            "revoke_refresh_token": r.get("revokeRefreshToken", False),
            "sso_session_idle_timeout": duration(r.get("ssoSessionIdleTimeout")),
            "sso_session_max_lifespan": duration(r.get("ssoSessionMaxLifespan")),
            "offline_session_idle_timeout": duration(r.get("offlineSessionIdleTimeout")),
            "access_token_lifespan": duration(r.get("accessTokenLifespan")),
            "access_code_lifespan": duration(r.get("accessCodeLifespan")),
        }
        # Always written: absent, the provider falls back to built-in names and
        # would re-bind a realm that uses a custom flow.
        for json_key, hcl in FLOW_BINDINGS:
            settings[hcl] = r.get(json_key)
        settings["attributes"] = {k: attributes[k] for k in REALM_ATTRIBUTE_ALLOWLIST if attributes.get(k) not in (None, "")} or None
        settings["security_headers"] = {
            "x_frame_options": headers.get("xFrameOptions", ""),
            "content_security_policy": headers.get("contentSecurityPolicy", ""),
            "content_security_policy_report_only": headers.get("contentSecurityPolicyReportOnly", ""),
            "x_content_type_options": headers.get("xContentTypeOptions", ""),
            "x_robots_tag": headers.get("xRobotsTag", ""),
            "x_xss_protection": headers.get("xXSSProtection", ""),
            "strict_transport_security": headers.get("strictTransportSecurity", ""),
            "referrer_policy": headers.get("referrerPolicy", ""),
        }
        if r.get("bruteForceProtected"):
            settings["brute_force_detection"] = {
                "permanent_lockout": r.get("permanentLockout", False),
                "max_login_failures": r.get("failureFactor", 30),
                "wait_increment_seconds": r.get("waitIncrementSeconds", 60),
                "max_failure_wait_seconds": r.get("maxFailureWaitSeconds", 900),
                "failure_reset_time_seconds": r.get("maxDeltaTimeSeconds", 43200),
            }
        else:
            settings["security_headers"] = Note(settings["security_headers"],
                                                "SECURITY: brute-force protection is OFF on this realm (no brute_force_detection block). Finding S4.")
        return settings

    def export_default_roles(self, r: dict) -> Note | list | None:
        role = r.get("defaultRole") or {}
        if not role.get("id"):
            return None
        names = []
        for c in self.get(f"/roles-by-id/{role['id']}/composites") or []:
            if c.get("clientRole"):
                names.append(f"{self.client_id_by_uuid.get(c['containerId'], '?')}/{c['name']}")
            else:
                names.append(c["name"])
        self.imports["keycloak_default_roles.this[0]"][""] = role["id"]
        names = sorted(names)
        admin = [n for n in names if n.startswith("realm-management/")]
        if admin:
            return Note(names, f"SECURITY: default roles include {', '.join(admin)}: every user gets them. Finding S1.")
        return names

    # --- client scopes, roles, groups ----------------------------------------------------

    def export_client_scopes(self) -> dict:
        scopes = {}
        for s in self.get("/client-scopes") or []:
            name = s["name"]
            if name in BUILTIN_CLIENT_SCOPES:
                continue
            if s.get("protocol", "openid-connect") != "openid-connect":
                self.warn(f"client scope '{name}' is {s.get('protocol')}; only OIDC scopes are managed. Skipped.")
                continue
            a = s.get("attributes") or {}
            text = a.get("consent.screen.text") or ""
            mappers = {}
            for m in self.get(f"/client-scopes/{s['id']}/protocol-mappers/models") or []:
                mappers[m["name"]] = {"protocol_mapper": m["protocolMapper"], "config": mapper_config(m)}
                self.imports["keycloak_generic_protocol_mapper.scope"][f"{name}/{m['name']}"] = f"client-scope/{s['id']}/{m['id']}"
            scopes[name] = strip_defaults({
                "description": s.get("description", ""),
                "consent_screen_text": text if bool_quoted(a, "display.on.consent.screen") and text else None,
                "include_in_token_scope": bool_quoted(a, "include.in.token.scope"),
                "include_in_openid_provider_metadata": bool_quoted(a, "include.in.openid.provider.metadata"),
                "protocol_mappers": sorted_map(mappers) or None,
            }, SCOPE_DEFAULTS, set())
            self.imports["keycloak_openid_client_scope.this"][name] = s["id"]
        return sorted_map(scopes)

    def export_realm_roles(self, r: dict) -> dict:
        default_role = (r.get("defaultRole") or {}).get("name")
        roles = {}
        for role in self.get_all("/roles", {"briefRepresentation": "false"}):
            name = role["name"]
            if name in BUILTIN_REALM_ROLES or name == default_role:
                continue
            composites = None
            if role.get("composite"):
                names = []
                for c in self.get(f"/roles-by-id/{role['id']}/composites") or []:
                    if c.get("clientRole") or c["name"] in BUILTIN_REALM_ROLES or c["name"] == default_role:
                        # The module holds every other role FLAT; adopting this as-is
                        # would strip the composite on the first apply. Stop instead.
                        self.fail(f"realm role '{name}' is a composite of '{c['name']}', which the module cannot express. Extend modules/realm/roles.tf first.")
                    names.append(c["name"])
                composites = sorted(names) or None
            roles[name] = {"description": role.get("description", ""), "attributes": join_multivalue(role.get("attributes")), "composite_roles": composites}
            self.imports["keycloak_role.realm_composite" if composites else "keycloak_role.realm"][name] = role["id"]
        return sorted_map(roles)

    def export_groups(self) -> dict:
        groups = {}
        for g in self.get_all("/groups", {"briefRepresentation": "false"}):
            if g.get("subGroupCount", 0) > 0 or g.get("subGroups"):
                self.warn(f"group '{g['name']}' has subgroups; this module manages top-level groups only.")
            mappings = self.get(f"/groups/{g['id']}/role-mappings") or {}
            realm_roles = sorted(m["name"] for m in mappings.get("realmMappings") or [])
            client_roles = {cid: sorted(m["name"] for m in v.get("mappings") or []) for cid, v in sorted((mappings.get("clientMappings") or {}).items())}
            if realm_roles or client_roles:
                self.imports["keycloak_group_roles.this"][g["name"]] = g["id"]
            groups[g["name"]] = {
                "description": non_empty(g.get("description")),
                "attributes": join_multivalue(g.get("attributes")),
                "realm_roles": realm_roles or None,
                "client_roles": client_roles or None,
            }
            self.imports["keycloak_group.this"][g["name"]] = g["id"]
        return sorted_map(groups)

    # --- clients ---------------------------------------------------------------------

    def export_clients(self, all_clients: list):
        clients = {}
        for c in all_clients:
            if c["clientId"] in BUILTIN_CLIENTS or c["clientId"] in PROVISIONER_CLIENT_IDS:
                continue
            if c.get("protocol", "openid-connect") != "openid-connect":
                self.warn(f"client '{c['clientId']}' is {c.get('protocol')}; only OIDC clients are managed. Skipped.")
                continue
            clients[c["clientId"]] = self.export_client(c)
        clients = sorted_map(clients)
        if self.missing_refresh_tokens:
            return Note(clients,
                        "use.refresh.tokens is absent on some clients live. Keycloak's effective default for a missing attribute is",
                        "true, so `use_refresh_tokens = true` is the faithful value, but the provider reads absence as false: the",
                        "first plan shows `use_refresh_tokens: false -> true` on each of them. No behaviour changes. Affected: "
                        + ", ".join(self.missing_refresh_tokens) + ".")
        return clients

    def export_client(self, c: dict):
        cid, uuid, a = c["clientId"], c["id"], c.get("attributes") or {}
        comments: list[str] = []
        standard, implicit = c.get("standardFlowEnabled", False), c.get("implicitFlowEnabled", False)
        dag, sa = c.get("directAccessGrantsEnabled", False), c.get("serviceAccountsEnabled", False)
        browser = standard or implicit
        public = c.get("publicClient", False)
        access_type = "PUBLIC" if public else ("BEARER-ONLY" if c.get("bearerOnly") else "CONFIDENTIAL")
        redirects, origins = sorted(c.get("redirectUris") or []), sorted(c.get("webOrigins") or [])
        post_logout = a.get("post.logout.redirect.uris")

        # The module declares both fields EMPTY without the flow that uses them: the
        # provider's guard reads STATE, so such a client cannot be written otherwise.
        if not browser and redirects:
            comments.append(f"live redirectUris {json.dumps(redirects)} are cleared on the first update: inert without a browser flow, and the provider refuses to write them.")
        if not (browser or dag) and origins:
            comments.append(f"live webOrigins {json.dumps(origins)} are cleared on the first update: inert without a browser or direct-grant flow.")
        pkce = a.get("pkce.code.challenge.method") or None
        if public and browser and not pkce:
            comments.append("SECURITY: public browser client without PKCE. Finding S7.")
        if public and browser and any(u in ("/*", "*") for u in redirects):
            comments.append("SECURITY: public client with a wildcard redirect URI. Finding S5.")
        if "use.refresh.tokens" not in a:
            self.missing_refresh_tokens.append(cid)

        extra_config = {k: v for k, v in sorted(a.items())
                        if k not in CLIENT_FIRST_CLASS_ATTRIBUTES and k not in CLIENT_NOISE_ATTRIBUTES
                        and not k.startswith(CLIENT_NOISE_PREFIXES) and v not in (None, "")}
        # extra_config is tracked per configured key; an import has none yet, so the
        # first plan writes every listed key back.
        if "use.refresh.tokens" not in a or extra_config or (not browser and redirects):
            self.changes["keycloak_openid_client.this"] += 1

        mappers = {}
        for m in self.get(f"/clients/{uuid}/protocol-mappers/models") or []:
            mappers[m["name"]] = {"protocol_mapper": m["protocolMapper"], "config": mapper_config(m)}
            self.imports["keycloak_generic_protocol_mapper.client"][f"{cid}/{m['name']}"] = f"client/{uuid}/{m['id']}"

        roles = {}
        for role in self.get_all(f"/clients/{uuid}/roles", {"briefRepresentation": "false"}):
            if role["name"] in AUTO_CLIENT_ROLES:
                continue
            if role.get("composite"):
                self.fail(f"client role {cid}/{role['name']} is composite; the module declares client roles flat. Extend modules/realm/clients.tf first.")
            roles[role["name"]] = {"description": role.get("description", ""), "attributes": join_multivalue(role.get("attributes"))}
            self.imports["keycloak_role.client"][f"{cid}/{role['name']}"] = role["id"]

        sa_realm, sa_client = [], {}
        if sa:
            user_id = (self.get(f"/clients/{uuid}/service-account-user") or {}).get("id")
            mappings = (self.get(f"/users/{user_id}/role-mappings") or {}) if user_id else {}
            for m in mappings.get("realmMappings") or []:
                if not m["name"].startswith("default-roles-"):
                    sa_realm.append(m["name"])
                    self.imports["keycloak_openid_client_service_account_realm_role.this"][f"{cid}/{m['name']}"] = f"{user_id}/{m['id']}"
            for container, v in sorted((mappings.get("clientMappings") or {}).items()):
                names = [m for m in v.get("mappings") or [] if not (container == cid and m["name"] in AUTO_CLIENT_ROLES)]
                for m in names:
                    self.imports["keycloak_openid_client_service_account_role.this"][f"{cid}/{container}/{m['name']}"] = f"{user_id}/{v['id']}/{m['id']}"
                if names:
                    sa_client[container] = sorted(m["name"] for m in names)
            privileged = [f"realm-management/{r}" for r in sa_client.get("realm-management", [])]
            if privileged:
                comments.append(f"service account holds realm administration roles: {', '.join(privileged)}.")

        overrides = {k: self.flow_alias_by_id.get(v) for k, v in (c.get("authenticationFlowBindingOverrides") or {}).items() if v}
        entry = strip_defaults({
            "name": c.get("name", ""), "description": c.get("description", ""), "enabled": c.get("enabled", True),
            "access_type": access_type,
            "standard_flow_enabled": standard, "implicit_flow_enabled": implicit,
            "direct_access_grants_enabled": dag, "service_accounts_enabled": sa,
            "root_url": c.get("rootUrl", ""), "base_url": c.get("baseUrl", ""), "admin_url": c.get("adminUrl", ""),
            "valid_redirect_uris": redirects if browser else None,
            "valid_post_logout_redirect_uris": sorted(post_logout.split(MULTIVALUE_SEPARATOR)) if post_logout else None,
            "web_origins": origins if (browser or dag) else None,
            "pkce_code_challenge_method": pkce,
            "full_scope_allowed": c.get("fullScopeAllowed", True),
            "consent_required": c.get("consentRequired", False),
            "frontchannel_logout_enabled": c.get("frontchannelLogout", False),
            "use_refresh_tokens": bool_quoted(a, "use.refresh.tokens", default=True),
            "extra_config": extra_config or None,
            "authentication_flow_binding_overrides": {"browser": overrides.get("browser"), "direct_grant": overrides.get("direct_grant")} if overrides else None,
            "default_scopes": sorted(c.get("defaultClientScopes") or []),
            "optional_scopes": sorted(c.get("optionalClientScopes") or []),
            "protocol_mappers": sorted_map(mappers) or None,
            "roles": sorted_map(roles) or None,
            "service_account_realm_roles": sorted(sa_realm) or None,
            "service_account_client_roles": sa_client or None,
        }, CLIENT_DEFAULTS, CLIENT_ALWAYS)
        self.imports["keycloak_openid_client.this"][cid] = uuid
        # Not importable in the provider: these plan as creates that PUT a list equal
        # to live -- a server-side no-op. A create showing a DIFFERENT list is a real
        # change wearing an import's clothes.
        self.creates["keycloak_openid_client_default_scopes.this"] += 1
        self.creates["keycloak_openid_client_optional_scopes.this"] += 1
        return Note(entry, *comments) if comments else entry

    # --- identity providers ----------------------------------------------------------

    def export_identity_providers(self) -> dict:
        providers = {}
        for p in self.get("/identity-provider/instances") or []:
            alias, cfg, pid = p["alias"], p.get("config") or {}, p.get("providerId")
            if pid not in ("oidc", "keycloak-oidc", "microsoft"):
                self.warn(f"identity provider '{alias}' is {pid}; unsupported by the module. Skipped.")
                continue
            mappers = {}
            for m in self.get(f"/identity-provider/instances/{alias}/mappers") or []:
                mappers[m["name"]] = {"identity_provider_mapper": m["identityProviderMapper"], "config": dict(sorted((m.get("config") or {}).items()))}
                self.imports["keycloak_custom_identity_provider_mapper.this"][f"{alias}/{m['name']}"] = f"{alias}/{m['id']}"
            entry = {
                "provider_id": pid, "display_name": non_empty(p.get("displayName")),
                "enabled": p.get("enabled", True), "trust_email": p.get("trustEmail", False),
                "store_token": p.get("storeToken", False), "link_only": p.get("linkOnly", False),
                "first_broker_login_flow_alias": p.get("firstBrokerLoginFlowAlias", "first broker login"),
                "client_id": cfg.get("clientId", ""),
                # The secret is NOT exported: the API returns a mask, and the module
                # defaults to that mask and pins it with ignore_changes.
                "default_scopes": non_empty(cfg.get("defaultScope")),
                "authorization_url": non_empty(cfg.get("authorizationUrl")), "token_url": non_empty(cfg.get("tokenUrl")),
                "user_info_url": non_empty(cfg.get("userInfoUrl")), "jwks_url": non_empty(cfg.get("jwksUrl")),
                "logout_url": non_empty(cfg.get("logoutUrl")), "issuer": non_empty(cfg.get("issuer")),
                "tenant_id": non_empty(cfg.get("tenantId")),
                "extra_config": {k: v for k, v in sorted(cfg.items()) if k not in IDP_FIRST_CLASS_CONFIG and v not in (None, "")} or None,
                "mappers": sorted_map(mappers) or None,
            }
            resource = "keycloak_oidc_microsoft_identity_provider.this" if pid == "microsoft" else "keycloak_oidc_identity_provider.this"
            self.imports[resource][alias] = alias
            self.changes[resource] += 1  # extra_config / provider_id write-backs on the first update
            providers[alias] = entry
        return sorted_map(providers)

    # --- authentication flows ---------------------------------------------------------

    def export_flows(self, all_flows: list, realm: dict) -> tuple[dict, dict, dict]:
        bound = {realm.get(json_key) for json_key, _ in FLOW_BINDINGS}
        flows, subflows, executions = {}, {}, {}
        for f in all_flows:
            if f.get("builtIn") or not f.get("topLevel"):
                continue
            alias = f["alias"]
            # A flow bound nowhere is fully configured and executed never.
            note = "bound by the realm" if alias in bound else "orphan: bound nowhere at realm level (check brokers and client overrides)"
            flows[alias] = Note({"description": f.get("description", ""), "provider_id": f.get("providerId", "basic-flow")}, note)
            self.imports["keycloak_authentication_flow.this"][alias] = f["id"]
            counters: Counter = Counter()
            stack: list[str] = []
            for item in self.get(f"/authentication/flows/{alias}/executions") or []:
                level = item.get("level", 0)
                parent = alias if level == 0 else stack[level - 1]
                # Priorities are reproduced as-is: the provider does not compute them,
                # live values are often non-contiguous, and renumbering reorders.
                detail = self.get(f"/authentication/executions/{item['id']}") or {}
                requirement = detail.get("requirement") or item.get("requirement", "DISABLED")
                priority = detail.get("priority", item.get("priority", 0))
                if item.get("authenticationFlow"):
                    sub = self.get(f"/authentication/flows/{item['flowId']}") or {}
                    stack = stack[:level] + [sub.get("alias")]
                    if level > 1:
                        self.warn(f"subflow '{sub.get('alias')}' is deeper than two levels. Skipped with its children.")
                        continue
                    subflows[sub["alias"]] = {"parent_flow": parent, "description": sub.get("description", ""),
                                              "provider_id": sub.get("providerId", "basic-flow"),
                                              "requirement": requirement, "priority": priority}
                    level_name = "l1" if level == 0 else "l2"
                    self.imports[f"keycloak_authentication_subflow.{level_name}"][sub["alias"]] = f"{parent}/{sub['id']}"
                    continue
                counters[parent] += 1
                key = f"{parent}/{counters[parent]}"
                config = None
                if item.get("authenticationConfig"):
                    cfg = self.get(f"/authentication/config/{item['authenticationConfig']}") or {}
                    config = {"alias": cfg.get("alias", ""), "config": dict(sorted((cfg.get("config") or {}).items()))}
                    self.imports["keycloak_authentication_execution_config.this"][key] = f"{item['id']}/{item['authenticationConfig']}"
                executions[key] = {"parent_flow": parent, "authenticator": detail.get("authenticator") or item.get("providerId", ""),
                                   "requirement": requirement, "priority": priority, "config": config}
                self.imports["keycloak_authentication_execution.this"][key] = f"{parent}/{item['id']}"
        return sorted_map(flows), sorted_map(subflows), sorted_map(executions)


# --- File rendering ---------------------------------------------------------------------

def render_realm_file(module_name: str, module: dict, source_url: str, realm: str) -> str:
    lines = [
        f'# Realm "{realm}" on {source_url}, generated by scripts/keycloak/kc_export.py.',
        "#",
        "# Values are the live realm verbatim. Re-running the exporter into this",
        "# directory must produce no diff; a diff means the realm changed behind the",
        "# code (drift), or the code changed and was not applied. Generated comments",
        "# only: explanations belong in docs/keycloak-consolidation.md.",
        "",
        f'module "{module_name}" {{',
        '  source = "../modules/realm"',
        "",
        f"  realm = {hcl_string(realm)}",
    ]
    for key, value in module.items():
        plain = value.value if isinstance(value, Note) else value
        if key == "realm" or plain in (None, {}, []):
            continue
        lines += ["", f"  # --- {key.replace('_', ' ')} ---"] + render_entries({key: value}, "  ")
    return "\n".join(lines + ["}", ""])


def render_imports_file(module_name: str, imports: dict, realm: str, source_url: str) -> str:
    lines = [
        "# " + "=" * 76, "# TEMPORARY: delete this file after the first successful apply.", "# " + "=" * 76, "#",
        f'# Import blocks adopting the live realm "{realm}" on {source_url} into',
        f"# module.{module_name}. Generated by scripts/keycloak/kc_export.py.", "",
        "locals {", f"  {module_name}_import = {{",
    ]
    collections = {r: m for r, m in sorted(imports.items()) if "" not in m}
    for resource, mapping in collections.items():
        lines.append(f"    {re.sub(r'[^a-z0-9_]', '_', resource)} = {render_value(sorted_map(mapping), '    ')}")
    lines += ["  }", "}"]
    for resource, mapping in sorted(imports.items()):
        lines.append("")
        if "" in mapping:
            suffix = mapping[""]
            ident = hcl_string(realm) if suffix == realm else hcl_string(f"{realm}/{suffix}")
            lines += ["import {", f"  to = module.{module_name}.{resource}", f"  id = {ident}", "}"]
            continue
        local_key = re.sub(r"[^a-z0-9_]", "_", resource)
        lines += ["import {", f"  for_each = local.{module_name}_import.{local_key}",
                  f"  to       = module.{module_name}.{resource}[each.key]",
                  f'  id       = "{realm}/${{each.value}}"', "}"]
    return "\n".join(lines + [""])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", required=True, help="Keycloak base URL without the relative path")
    parser.add_argument("--base-path", default="/keycloak", help="Relative path Keycloak is served under")
    parser.add_argument("--realm", required=True, help="Realm to export")
    parser.add_argument("--out", required=True, help="Root directory to write realm-<slug>.tf and imports-<slug>.tf into")
    parser.add_argument("--admin-user", help="Password grant as this master-realm admin (password from $KC_ADMIN_PASSWORD or a prompt). Without it, client credentials are used.")
    parser.add_argument("--client-id", default="tofu-provisioner", help="Service-account client for the client-credentials grant; secret from $KC_PROVISIONER_SECRET or a prompt")
    parser.add_argument("--no-imports", action="store_true", help="Do not write imports-<slug>.tf (after adoption)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    admin = KeycloakAdmin(args.url, args.base_path)
    if args.admin_user:
        admin.login_password(args.admin_user, resolve_secret("KC_ADMIN_PASSWORD", f"Password for '{args.admin_user}': "))
    else:
        admin.login_client_credentials(args.client_id, resolve_secret("KC_PROVISIONER_SECRET", f"Client secret for '{args.client_id}': "))
    log(f"==> Keycloak {admin.server_version()} at {admin.base}, reading realm '{args.realm}'")

    exporter = RealmExporter(admin, args.realm)
    module = exporter.export()

    slug = slugify(args.realm)
    module_name = slug.replace("-", "_")
    os.makedirs(args.out, exist_ok=True)
    written = [os.path.join(args.out, f"realm-{slug}.tf")]
    with open(written[0], "w", encoding="utf-8", newline="\n") as handle:
        handle.write(render_realm_file(module_name, module, admin.base, args.realm))
    if not args.no_imports:
        written.append(os.path.join(args.out, f"imports-{slug}.tf"))
        with open(written[1], "w", encoding="utf-8", newline="\n") as handle:
            handle.write(render_imports_file(module_name, exporter.imports, args.realm, admin.base))

    tofu = shutil.which("tofu")
    if tofu:
        subprocess.run([tofu, "fmt", *written], check=False)
    else:
        log("WARNING: tofu not on PATH; run `tofu fmt` in the root.")

    # The numbers the adoption plan must show. Anything else means the module or
    # this exporter is wrong: fix the code, never the realm.
    imports = sum(len(v) for v in exporter.imports.values())
    log(f"\n==> Wrote {', '.join(written)}\n")
    log("    Expected first plan for this realm:")
    log(f"      {imports:>4} to import")
    log(f"      {sum(exporter.creates.values()):>4} to add     (non-importable, re-asserting creates)")
    log(f"      {sum(exporter.changes.values()):>4} to change  (one-time write-backs of live values)")
    log("         0 to destroy  (any replacement is a bug in the module or this exporter)")
    for title, counter in (("Imports", Counter({k: len(v) for k, v in exporter.imports.items()})),
                           ("Creates", exporter.creates), ("Changes", exporter.changes)):
        log(f"    {title} by resource:")
        for resource in sorted(counter):
            log(f"      {counter[resource]:>4}  {resource}")
    if exporter.warnings:
        log(f"\n    {len(exporter.warnings)} warning(s) above need a decision before apply.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
