-- product-b: one-time database bootstrap for a server environment.
--
-- Run ONCE per environment with the server's admin login, before the first product-b-db migration
-- Job. Nothing runs this file by itself:
--
--   psql "host=<pg-host> port=5432 dbname=postgres user=<admin-login> sslmode=require" \
--        -v migrator_password="'<from-key-vault>'" -v app_password="'<from-key-vault>'" \
--        -f deploy/db-bootstrap/01-roles-and-database.sql
--
-- The two passwords are psql VARIABLES, so neither is ever written into this file, into git or into
-- shell history beyond the one invocation. Generate them, store them as the Key Vault objects the
-- charts read, and pass them from there.
--
-- WHAT THIS CREATES, AND WHY HERE AND NOT IN A MIGRATION
--   app_migrator  LOGIN. Owns the database and every schema the migrator creates. The migration Job
--                 connects as it. It needs no CREATEROLE: the one role migrations reference
--                 (tenant_role) is created here first, so their IF NOT EXISTS skips.
--   app_runtime   LOGIN. What the API, MCP host and worker connect as. It runs no DDL. On tenant
--                 schemas it acts through per-tenant roles granted to it when a tenant is
--                 provisioned; on the platform schema it gets the default privileges below.
--   tenant_role   NOLOGIN. The shared role the append-only grants are written against.
--   product_b     The database, owned by app_migrator.
--
-- Creating roles and databases needs CREATEROLE/CREATEDB, which no workload holds. That is why this
-- is a bootstrap step and not part of the Job: the Job's credential cannot create logins.

\set ON_ERROR_STOP on

SELECT 'CREATE ROLE app_migrator LOGIN PASSWORD ' || :'migrator_password'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_migrator') \gexec

SELECT 'CREATE ROLE app_runtime LOGIN PASSWORD ' || :'app_password'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_runtime') \gexec

SELECT 'CREATE ROLE tenant_role NOLOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tenant_role') \gexec

-- On a managed PostgreSQL server the admin is not a superuser and may only create a database owned
-- by a role it is a member of.
GRANT app_migrator TO CURRENT_USER;

-- C collation: sort order and comparisons are byte-wise and identical on every server, whatever its
-- OS locale. Language-aware sorting is done explicitly, per query, where the product needs it.
SELECT 'CREATE DATABASE product_b OWNER app_migrator ENCODING ''UTF8'' LC_COLLATE ''C'' LC_CTYPE ''C'' TEMPLATE template0'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'product_b') \gexec

\connect product_b

REVOKE ALL ON DATABASE product_b FROM PUBLIC;
GRANT CONNECT ON DATABASE product_b TO app_runtime;

ALTER SCHEMA public OWNER TO app_migrator;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO app_runtime;

-- Whatever app_migrator creates in the platform schema, app_runtime may read and write. These are
-- DEFAULT privileges, declared once, so every table a LATER migration adds is covered without
-- anybody remembering to grant it. (The older product had exactly that gap: each new table needed a
-- hand-written GRANT, and the first symptom of a forgotten one was a permission error in production.)
ALTER DEFAULT PRIVILEGES FOR ROLE app_migrator IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_runtime;
ALTER DEFAULT PRIVILEGES FOR ROLE app_migrator IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO app_runtime;
