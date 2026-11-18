#!/usr/bin/env python3
"""kc_bootstrap.py - create the `tofu-provisioner` service account in `master`.

The credential infra/org/keycloak authenticates with, one per Keycloak
INSTANCE:

  1. a confidential service-account client `tofu-provisioner` in `master`
     (Standard Flow OFF, Direct Access Grants OFF, Service Accounts ON);
  2. its service account granted the master realm role `admin`, which is what
     makes it instance-wide: it can read and manage every realm, and create new
     ones, which a per-realm `realm-admin` cannot.

Idempotent: re-running against a prepared instance changes nothing and reprints
the secret, so `--dry-run` doubles as a configuration check.

WHY THIS CLIENT IS NEVER MANAGED BY TOFU
If OpenTofu owned it, a bad apply could rotate its own secret or disable its
service account and lock the stack out of the instance, with no way back except
the admin console. It is created here, deliberately, and excluded from the
module.

WHY THE ADMIN PASSWORD IS NEVER AN ARGUMENT OR A CONSTANT
The bash script this replaced had a production admin password committed to git.
This one reads it from $KC_ADMIN_PASSWORD or prompts for it, and nothing else.

USAGE
  python scripts/keycloak/kc_bootstrap.py --url https://dev.example.com --admin-user <admin> --dry-run
  python scripts/keycloak/kc_bootstrap.py --url https://dev.example.com --admin-user <admin>

Put the printed secret into infra/org/keycloak/<root>/terraform.tfvars
(git-ignored) and into the instance's Key Vault. It is shown once; re-run to see
it again.
"""

from __future__ import annotations

import argparse
import sys

from kc_admin import KeycloakAdmin, KeycloakError, log, resolve_secret

PROVISIONER_DESCRIPTION = (
    "Service account used by OpenTofu (infra/org/keycloak) to manage every realm on "
    "this instance. Created by scripts/keycloak/kc_bootstrap.py and deliberately not managed by "
    "OpenTofu - see that script for why."
)

# CLIENT.DESCRIPTION is VARCHAR(255). On SQL Server an over-length insert is
# rejected outright and Keycloak reports it as a bare `500 unknown_error` naming
# neither field nor limit, so the check lives here where the message can.
assert len(PROVISIONER_DESCRIPTION) <= 255, "client description exceeds VARCHAR(255)"


def desired_client(client_id: str) -> dict:
    return {
        "clientId": client_id,
        "name": client_id,
        "description": PROVISIONER_DESCRIPTION,
        "protocol": "openid-connect",
        "enabled": True,
        "publicClient": False,
        "bearerOnly": False,
        "serviceAccountsEnabled": True,
        "standardFlowEnabled": False,
        "implicitFlowEnabled": False,
        "directAccessGrantsEnabled": False,
        "authorizationServicesEnabled": False,
        "frontchannelLogout": False,
    }


# A pre-existing client with the right name but the wrong flags is the worst
# outcome: everything looks fine until the provider fails to get a token, or gets
# one through a flow that should not have been enabled.
FLAG_CHECKS = (
    ("publicClient", False, "publicClient=true (must be confidential)"),
    ("serviceAccountsEnabled", True, "serviceAccountsEnabled=false (must be true)"),
    ("standardFlowEnabled", False, "standardFlowEnabled=true (must be false)"),
    ("directAccessGrantsEnabled", False, "directAccessGrantsEnabled=true (must be false)"),
    ("implicitFlowEnabled", False, "implicitFlowEnabled=true (must be false)"),
    ("enabled", True, "enabled=false"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", required=True, help="Keycloak base URL without the relative path, e.g. https://dev.example.com")
    parser.add_argument("--base-path", default="/keycloak", help="Relative path Keycloak is served under (default: /keycloak). Pass '' for an instance at the root.")
    parser.add_argument("--admin-realm", default="master", help="Realm to authenticate against and to create the client in (default: master)")
    parser.add_argument("--admin-user", required=True, help="Admin username. The password comes from $KC_ADMIN_PASSWORD or a prompt.")
    parser.add_argument("--admin-client-id", default="admin-cli", help="Public client used for the password grant (default: admin-cli)")
    parser.add_argument("--client-id", default="tofu-provisioner", help="clientId of the provisioner to create (default: tofu-provisioner)")
    parser.add_argument("--role", default="admin", help="Realm role in the admin realm to grant the service account (default: admin)")
    parser.add_argument("--fix", action="store_true", help="Correct a misconfigured existing client instead of failing")
    parser.add_argument("--dry-run", action="store_true", help="Report what would change; make no writes and read no secret")
    parser.add_argument("--quiet", action="store_true", help="Print only the secret on stdout")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    def say(message: str) -> None:
        if not args.quiet:
            log(message)

    password = resolve_secret("KC_ADMIN_PASSWORD", f"Password for '{args.admin_user}' in realm '{args.admin_realm}': ")

    admin = KeycloakAdmin(args.url, args.base_path, auth_realm=args.admin_realm)
    say(f"==> Authenticating as '{args.admin_user}' against {admin.base}/realms/{args.admin_realm}")
    admin.login_password(args.admin_user, password, client_id=args.admin_client_id)
    say("    ok")

    realm = args.admin_realm

    # --- Step 1: the client ---------------------------------------------------
    say(f"==> Client '{args.client_id}' in realm '{realm}'")
    existing = admin.get(f"/realms/{realm}/clients", {"clientId": args.client_id}) or []
    client_uuid = existing[0]["id"] if existing else None

    if client_uuid:
        say(f"    exists ({client_uuid})")
        mismatches = [message for key, wanted, message in FLAG_CHECKS if existing[0].get(key) != wanted]
        if mismatches:
            for message in mismatches:
                log(f"WARNING: {args.client_id}: {message}")
            if args.dry_run:
                say("    would correct with --fix (dry run)")
            elif args.fix:
                body = dict(existing[0])
                body.update(desired_client(args.client_id))
                admin.put(f"/realms/{realm}/clients/{client_uuid}", body)
                say("    corrected (--fix)")
            else:
                raise SystemExit(f"Client '{args.client_id}' exists but is misconfigured. Re-run with --fix, or fix it in the admin console.")
        else:
            say("    configuration is correct")
    elif args.dry_run:
        say("    MISSING - would create (dry run)")
    else:
        admin.post(f"/realms/{realm}/clients", desired_client(args.client_id))
        created = admin.get(f"/realms/{realm}/clients", {"clientId": args.client_id}) or []
        if not created:
            raise SystemExit(f"Created '{args.client_id}' but could not read it back.")
        client_uuid = created[0]["id"]
        say(f"    created ({client_uuid})")

    # --- Step 2: the role grant -------------------------------------------------
    if client_uuid is None:
        say(f"==> Role grant '{args.role}': skipped (client would not exist yet in a dry run)")
    else:
        say(f"==> Granting realm role '{args.role}' to the service account")
        try:
            role = admin.get(f"/realms/{realm}/roles/{args.role}")
        except KeycloakError as error:
            if error.status == 404:
                raise SystemExit(f"Realm role '{args.role}' does not exist in '{realm}'.") from None
            raise
        sa_user = admin.get(f"/realms/{realm}/clients/{client_uuid}/service-account-user")
        sa_user_id = sa_user["id"]
        current = admin.get(f"/realms/{realm}/users/{sa_user_id}/role-mappings/realm") or []
        if any(r["name"] == args.role for r in current):
            say("    already granted")
        elif args.dry_run:
            say("    would grant (dry run)")
        else:
            # Keycloak treats a duplicate assignment as a no-op, so this is safe to repeat.
            admin.post(f"/realms/{realm}/users/{sa_user_id}/role-mappings/realm", [{"id": role["id"], "name": role["name"]}])
            say("    granted")

    # --- Step 3: the secret -----------------------------------------------------
    if args.dry_run:
        say("")
        say("Dry run - nothing was written, and no secret was read.")
        return 0

    secret = (admin.get(f"/realms/{realm}/clients/{client_uuid}/client-secret") or {}).get("value")
    if not secret:
        raise SystemExit(f"Could not read the client secret for '{args.client_id}'.")

    if args.quiet:
        print(secret)
        return 0

    log("")
    log("--------------------------------------------------------------------------")
    log(f" Instance   {admin.base}")
    log(f" Realm      {realm}")
    log(f" Client     {args.client_id}  ({client_uuid})")
    log(f" Role       {args.role} (realm role in {realm}, instance-wide)")
    log("--------------------------------------------------------------------------")
    log("")
    log("Put this in infra/org/keycloak/<root>/terraform.tfvars as provisioner_client_secret,")
    log("and a backup copy in the instance's Key Vault:")
    print(secret)
    log("")
    log("The secret is now in your terminal scrollback. If that matters, re-run with --quiet.")
    log("Reminder: this client is excluded from OpenTofu on purpose.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
