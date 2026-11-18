# Postgres application roles

[`create-app-roles.sql`](create-app-roles.sql) creates or converges the login roles on
a product-a PostgreSQL Flexible Server. OpenTofu cannot do this in that stack: ARM
exposes databases, not roles. The trade-off is explained in
[`../../product-a/aks-prod/postgres.tf`](../../product-a/aks-prod/postgres.tf). The org
stack makes the opposite choice and uses the `cyrilgdn/postgresql` provider; see
[`../../org/postgres/app-roles.tf`](../../org/postgres/app-roles.tf).

## Properties

- **Idempotent.** It creates a role only if it is missing, then sets the password,
  ownership and grants on every run. Re-running it after a Key Vault rotation is the
  rotation.
- **No password on a command line.** Passwords reach psql through environment
  variables read with `\getenv`, never through `-v name=value` or `-c "... PASSWORD '...'"`.
  The script refuses to run if a variable is missing. Otherwise psql would send the
  literal `:'var'` text as a valid, wrong password.
- **The audit writer role is created elsewhere on purpose.** It must come from the
  audit service's own migration, which installs the append-only trigger in the same
  pass.

## Running it

Run it from inside the cluster. The cluster's static egress IP is already in the
server firewall, so no operator IP has to be opened. The passwords go from Key Vault
into a short-lived Secret through files, never through argv:

```bash
env=prod
kv="kv-product-a-${env}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

for pair in PGPASSWORD:postgres--admin--password \
            KEYCLOAK_DB_PASSWORD:keycloak--db--password \
            PRODUCT_A_DB_PASSWORD:product-a--db--password \
            PRODUCT_A_AUDIT_PROVISIONER_PASSWORD:product-a-audit--provisioner--password; do
  az keyvault secret show --vault-name "$kv" --name "${pair#*:}" \
    --query value -o tsv | tr -d '\r\n' > "$tmp/${pair%%:*}"
done

kubectl -n platform-tools create secret generic pg-role-bootstrap --from-file="$tmp"
kubectl -n platform-tools create configmap pg-role-script --from-file=create-app-roles.sql

kubectl -n platform-tools run pgclient --rm -i --restart=Never --image=postgres:17-alpine \
  --overrides='{
    "spec": {"containers": [{
      "name": "pgclient", "image": "postgres:17-alpine",
      "envFrom": [{"secretRef": {"name": "pg-role-bootstrap"}}],
      "volumeMounts": [{"name": "sql", "mountPath": "/sql"}],
      "command": ["psql", "host=psql-product-a-prod.postgres.database.azure.com port=5432 dbname=postgres user=pgadmin sslmode=require", "-f", "/sql/create-app-roles.sql"]
    }],
    "volumes": [{"name": "sql", "configMap": {"name": "pg-role-script"}}]}
  }'

kubectl -n platform-tools delete secret pg-role-bootstrap
kubectl -n platform-tools delete configmap pg-role-script
```

Validation on a workstation is limited to `psql --file` against a disposable local
PostgreSQL 15+ that has the three databases created. No offline syntax checker for
psql meta-commands exists.
