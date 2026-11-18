"""Minimal Keycloak admin REST client shared by kc_export.py and kc_bootstrap.py.

Standard library only (urllib, json, getpass): no virtualenv, no pip, runs with the
Python 3 already on the workstation. Windows-safe: nothing here shells out, so the
CRLF-emitting jq builds that broke the old bash script is not involved.

Two ways to authenticate against the auth realm (normally `master`):

  * password grant with a human admin account through the built-in `admin-cli`
    public client (bootstrap, first export);
  * client-credentials grant as the `tofu-provisioner` service account
    (every later export).

Passwords and secrets are never accepted as command-line arguments: arguments are
visible to other processes and land in shell history. They come from an
environment variable or an interactive prompt, see `resolve_secret`.
"""

from __future__ import annotations

import getpass
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

MASK = "**********"  # what Keycloak returns for any secret it will not disclose


def log(message: str) -> None:
    """All commentary goes to stderr so stdout can carry a value (e.g. a secret)."""
    print(message, file=sys.stderr, flush=True)


def resolve_secret(env_var: str, prompt: str) -> str:
    """Read a secret from `env_var`, or prompt for it. Never from argv."""
    value = os.environ.get(env_var, "")
    if value:
        return value
    if not sys.stdin.isatty():
        raise SystemExit(f"No {env_var} in the environment and no terminal to prompt on.")
    value = getpass.getpass(prompt)
    if not value:
        raise SystemExit("Empty secret.")
    return value


class KeycloakError(Exception):
    def __init__(self, status: int, method: str, path: str, body: str):
        super().__init__(f"{method} {path} -> HTTP {status}: {body[:500]}")
        self.status = status
        self.method = method
        self.path = path
        self.body = body


class KeycloakAdmin:
    """Thin wrapper over /admin/realms with automatic re-authentication.

    Admin access tokens are short-lived (60 s in a default master realm) and an
    export makes hundreds of calls, so a 401 mid-run is a realistic outcome. The
    first 401 on any request re-authenticates once and retries.
    """

    def __init__(self, url: str, base_path: str = "/keycloak", auth_realm: str = "master", timeout: int = 60):
        base_path = base_path.rstrip("/")
        self.base = url.rstrip("/") + base_path
        self.admin_base = f"{self.base}/admin"
        self.auth_realm = auth_realm
        self.timeout = timeout
        self._token: str | None = None
        self._token_form: dict[str, str] | None = None

    # --- authentication ------------------------------------------------------

    def login_password(self, username: str, password: str, client_id: str = "admin-cli") -> None:
        self._token_form = {
            "grant_type": "password",
            "client_id": client_id,
            "username": username,
            "password": password,
        }
        self._authenticate()

    def login_client_credentials(self, client_id: str, client_secret: str) -> None:
        self._token_form = {
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
        }
        self._authenticate()

    def _authenticate(self) -> None:
        assert self._token_form is not None
        token_url = f"{self.base}/realms/{self.auth_realm}/protocol/openid-connect/token"
        data = urllib.parse.urlencode(self._token_form).encode()
        request = urllib.request.Request(token_url, data=data, method="POST")
        request.add_header("Content-Type", "application/x-www-form-urlencoded")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            raw = error.read().decode("utf-8", "replace")
            try:
                parsed = json.loads(raw)
                reason = parsed.get("error_description") or parsed.get("error") or raw
            except ValueError:
                reason = self._not_json_hint(token_url)
            raise SystemExit(f"Authentication failed: {reason}") from None
        except urllib.error.URLError as error:
            raise SystemExit(f"Could not reach {token_url}: {error.reason}") from None

        try:
            parsed = json.loads(raw)
        except ValueError:
            raise SystemExit(self._not_json_hint(token_url)) from None
        token = parsed.get("access_token")
        if not token:
            raise SystemExit(f"No access_token in token response from {token_url}.")
        self._token = token

    @staticmethod
    def _not_json_hint(url: str) -> str:
        return (
            "The token endpoint did not return JSON, so the request never reached Keycloak.\n"
            f"  Tried: {url}\n"
            "  Almost always a wrong --base-path. Both instances set\n"
            "  KC_HTTP_RELATIVE_PATH=/keycloak, which is the default here."
        )

    # --- plumbing -------------------------------------------------------------

    def request(self, method: str, path: str, body=None, params: dict | None = None, *, admin: bool = True):
        """Perform one call. `path` is relative to /admin (default) or to the base.

        Returns (status, parsed_json_or_None, raw_text). Raises KeycloakError on
        any non-2xx status other than the one retried 401.
        """
        if self._token is None:
            raise RuntimeError("not authenticated")
        root = self.admin_base if admin else self.base
        # Flow aliases and similar path segments may contain spaces; query
        # parameters travel separately via `params`, so quoting the whole path is safe.
        url = root + urllib.parse.quote(path, safe="/")
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)

        for attempt in range(2):
            data = None
            request = urllib.request.Request(url, method=method)
            request.add_header("Authorization", f"Bearer {self._token}")
            request.add_header("Accept", "application/json")
            if body is not None:
                data = json.dumps(body).encode()
                request.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(request, data=data, timeout=self.timeout) as response:
                    status = response.status
                    raw = response.read().decode("utf-8", "replace")
                    parsed = json.loads(raw) if raw.strip() else None
                    return status, parsed, raw
            except urllib.error.HTTPError as error:
                raw = error.read().decode("utf-8", "replace")
                if error.code == 401 and attempt == 0:
                    self._authenticate()
                    continue
                raise KeycloakError(error.code, method, path, raw) from None
            except urllib.error.URLError as error:
                raise SystemExit(f"Network error on {method} {url}: {error.reason}") from None
        raise RuntimeError("unreachable")

    def get(self, path: str, params: dict | None = None):
        _, parsed, _ = self.request("GET", path, params=params)
        return parsed

    def get_optional(self, path: str, params: dict | None = None):
        """GET that returns None on 404 instead of raising."""
        try:
            return self.get(path, params)
        except KeycloakError as error:
            if error.status == 404:
                return None
            raise

    def get_all(self, path: str, params: dict | None = None, page_size: int = 100) -> list:
        """GET a paginated list endpoint (first/max) until a short page comes back."""
        items: list = []
        first = 0
        while True:
            page_params = dict(params or {})
            page_params.update({"first": first, "max": page_size})
            page = self.get(path, page_params) or []
            items.extend(page)
            if len(page) < page_size:
                return items
            first += page_size

    def post(self, path: str, body=None):
        return self.request("POST", path, body=body)

    def put(self, path: str, body=None):
        return self.request("PUT", path, body=body)

    def server_version(self) -> str:
        info = self.get("/serverinfo")
        return (info or {}).get("systemInfo", {}).get("version", "unknown")
