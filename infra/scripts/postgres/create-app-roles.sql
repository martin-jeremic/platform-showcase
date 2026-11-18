-- create-app-roles.sql -- application login roles on psql-product-a-<env>.
--
-- Replaces a set of hand-run `kubectl run ... psql -c "CREATE ROLE ... PASSWORD '$pw'"`
-- one-liners. Those put the password in a command line (visible to `ps`, shell
-- history and the pod spec), were not re-runnable (CREATE ROLE fails the second
-- time), and could silently drift from the value in Key Vault.
--
-- This script is IDEMPOTENT: create-if-missing, then converge (password, ownership,
-- grants) on every run, so re-running it after a Key Vault rotation is the rotation.
--
-- Passwords arrive through psql variables read from the ENVIRONMENT with \getenv
-- (psql 15+). Never with -v name=value: that is argv again. See README.md for how
-- the environment is populated from Key Vault without touching a command line.
--
-- Run connected as the server administrator, which on Azure Flexible Server is
-- NOT a superuser (it is a member of azure_pg_admin).

\set ON_ERROR_STOP on

\getenv keycloak_password KEYCLOAK_DB_PASSWORD
\getenv app_password PRODUCT_A_DB_PASSWORD
\getenv provisioner_password PRODUCT_A_AUDIT_PROVISIONER_PASSWORD

-- Fail closed: an unset variable would otherwise be sent as the literal text
-- ":'keycloak_password'" and become a valid, wrong password.
\if :{?keycloak_password}
\else
  \echo 'KEYCLOAK_DB_PASSWORD is not set'
  \quit 1
\endif
\if :{?app_password}
\else
  \echo 'PRODUCT_A_DB_PASSWORD is not set'
  \quit 1
\endif
\if :{?provisioner_password}
\else
  \echo 'PRODUCT_A_AUDIT_PROVISIONER_PASSWORD is not set'
  \quit 1
\endif

-- ---------------------------------------------------------------------------
-- Roles. psql does NOT interpolate :'var' inside a dollar-quoted DO body, so the
-- statements that carry a password are built with format(%L) and run with \gexec.
-- The rest are plain DO blocks.
--
-- No ALTER ROLE ... NOSUPERUSER NOBYPASSRLS: the Azure admin is not a superuser,
-- and changing either attribute requires one even to turn it OFF. CREATE ROLE
-- already defaults to NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS, so it would
-- be a no-op that can only fail. Confirm with \du instead.
-- ---------------------------------------------------------------------------

SELECT format('CREATE ROLE %I LOGIN', r)
FROM unnest(ARRAY['keycloak', 'product_a_app', 'product_a_audit_provisioner']) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r)
\gexec

-- Converge every run: the password MUST equal the Key Vault value the chart mounts.
-- If they drift, the app fails authentication after its next restart, not at the
-- moment of the change.
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', 'keycloak', :'keycloak_password') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', 'product_a_app', :'app_password') \gexec
SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', 'product_a_audit_provisioner', :'provisioner_password') \gexec

-- ---------------------------------------------------------------------------
-- Database-level grants (run from the maintenance database).
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  -- The identity provider owns its database outright.
  EXECUTE 'ALTER DATABASE keycloak OWNER TO keycloak';

  -- Multi-tenant: the migrator issues CREATE SCHEMA per tenant, so CREATE on the
  -- database is required, not a convenience.
  EXECUTE 'GRANT CONNECT, CREATE, TEMPORARY ON DATABASE product_a TO product_a_app';

  -- The audit PROVISIONER creates and migrates the per-tenant schemas.
  EXECUTE 'GRANT CONNECT, CREATE ON DATABASE product_a_audit_logs TO product_a_audit_provisioner';
END
$$;

-- ---------------------------------------------------------------------------
-- Schema-level grants are PER DATABASE, so connect to each.
--
-- PostgreSQL 15+ no longer lets every role write to schema `public`. Without this
-- GRANT the identity provider connects successfully and then fails to create its
-- schema -- which reads like a permissions bug in the application rather than a
-- missing grant.
-- ---------------------------------------------------------------------------

\connect keycloak
DO $$
BEGIN
  EXECUTE 'GRANT ALL ON SCHEMA public TO keycloak';
END
$$;

-- ---------------------------------------------------------------------------
-- NOT HERE, ON PURPOSE: the audit WRITER role.
--
-- It is created by the audit service's own migration
-- (db-ops/01-runtime-role-and-append-only.sql in the service repository), which
-- creates the role AND installs the append-only trigger and its grants in one pass.
-- Creating the role here would give a working login WITHOUT the append-only
-- guarantee -- the failure that looks like success.
-- ---------------------------------------------------------------------------

\echo 'Roles converged. Verify with: \\du  and  \\l'
