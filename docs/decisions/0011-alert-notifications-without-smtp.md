# 0011 · Alert notifications without SMTP and without a mail permission

**Context.**
- **No SMTP relay** existed in the organisation.
- **Alertmanager went nowhere.** Every alert was routed to a `null` receiver.
- **The first manual setup failed open.** It had three weak points:
  - an Exchange application access policy;
  - a hand-copied Teams flow URL;
  - a two-year client secret that was never rotated.

**Decision.**
- **Mail through Microsoft Graph.**
  - Alertmanager sends mail through Graph `/sendMail` as a `webhook_config`, using OAuth2 client credentials.
  - The Entra application holds **no Graph permission at all**.
  - `Mail.Send` is granted only through Exchange "RBAC for Applications", scoped to the sender mailboxes. An Entra consent would be tenant-wide and additive.
  - A script proves the scope after every change: the senders are in scope, an unrelated mailbox is out of scope, and no other grant exists.
- **Teams through a Logic App.**
  - The Logic App has an HTTP trigger and posts an Adaptive Card.
  - It returns 200 or 502 synchronously, so failures surface in Alertmanager. The stock workflow template always returns 202.
- **Credentials are managed by OpenTofu.**
  - The client secret rotates on a schedule, with `create_before_destroy` and a new Key Vault version.
  - The Logic App's callback URL is stored in Key Vault too.
  - Alertmanager reads both as files mounted by CSI, so rotation needs no restart and no commit.
  - Two `check` blocks warn when the secret nears expiry and when the Teams connection is not authorised.

**Lessons.**
- **Start the subject with a word.** Alertmanager re-parses rendered templates as YAML. A subject beginning with `[FIRING:2]` parsed as a list, and Graph answered 400. Pin Alertmanager at 0.34 or later for payload templating.
- **Use `set`, not `merge`.** Sprig's `merge` treats `false` as empty, so `send_resolved: false` rendered as `true`. Overrides are applied one key at a time with `set`.
- **Check the wiring at render time.** The chart asserts that the CSI volume exists, is mounted, and is the source the receivers read. It also fails the render if any `REPLACE_WITH_` placeholder is left.
