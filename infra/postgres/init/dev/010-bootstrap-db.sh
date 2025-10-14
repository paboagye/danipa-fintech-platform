#!/usr/bin/env bash
set -euo pipefail

# The official Postgres image sets $POSTGRES_USER to the superuser (default 'postgres')
: "${POSTGRES_USER:=postgres}"
: "${POSTGRES_DB:=postgres}"

# Load Vault-rendered env
if [ -f /opt/secrets/db-bootstrap.env ]; then
  # normalize CRLF just in case
  tr -d '\r' < /opt/secrets/db-bootstrap.env > /tmp/db-bootstrap.env
  set -a
  . /tmp/db-bootstrap.env
  set +a
else
  echo "[bootstrap] ERROR: /opt/secrets/db-bootstrap.env not found"
  exit 1
fi

echo "[bootstrap] ENV=$ENVIRONMENT DB=$DB_NAME schema=$DB_SCHEMA app_role=$APP_ROLE ro_role=$RO_ROLE"

psql() { command psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"; }
psql_db() { command psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$DB_NAME" "$@"; }

# 1) Roles (idempotent via DO blocks)
psql <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${APP_ROLE}') THEN
    CREATE ROLE ${APP_ROLE} LOGIN PASSWORD '${APP_ROLE_PASSWORD}'
      NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION;
  ELSE
    -- keep passwords in sync with Vault
    EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', '${APP_ROLE}', '${APP_ROLE_PASSWORD}');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${RO_ROLE}') THEN
    CREATE ROLE ${RO_ROLE} LOGIN PASSWORD '${RO_ROLE_PASSWORD}'
      NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION;
  ELSE
    EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', '${RO_ROLE}', '${RO_ROLE_PASSWORD}');
  END IF;
END
\$\$;
SQL

# 2) Database (idempotent)
psql <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}') THEN
    PERFORM d.datname FROM pg_database d WHERE d.datname = current_database(); -- noop to keep lints happy
    EXECUTE 'CREATE DATABASE ${DB_NAME} OWNER ${APP_ROLE}';
  END IF;
END
\$\$;
SQL

# 3) Per-database grants + schema ownership
psql_db <<SQL
-- ensure schema exists and is owned by the app role
CREATE SCHEMA IF NOT EXISTS ${DB_SCHEMA} AUTHORIZATION ${APP_ROLE};

-- make app the owner of public schema, or lock it down; choose one:
-- ALTER SCHEMA public OWNER TO ${APP_ROLE};
-- or restrict 'public' usage:
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- database-level privileges
REVOKE ALL ON DATABASE ${DB_NAME} FROM PUBLIC;
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${APP_ROLE}, ${RO_ROLE};

-- schema usage
GRANT USAGE ON SCHEMA ${DB_SCHEMA} TO ${RO_ROLE};
GRANT USAGE, CREATE ON SCHEMA ${DB_SCHEMA} TO ${APP_ROLE};

-- existing objects (if any)
GRANT SELECT ON ALL TABLES IN SCHEMA ${DB_SCHEMA} TO ${RO_ROLE};
GRANT SELECT ON ALL SEQUENCES IN SCHEMA ${DB_SCHEMA} TO ${RO_ROLE};

-- default privileges for future objects created by APP_ROLE
ALTER DEFAULT PRIVILEGES FOR USER ${APP_ROLE} IN SCHEMA ${DB_SCHEMA}
  GRANT SELECT ON TABLES TO ${RO_ROLE};
ALTER DEFAULT PRIVILEGES FOR USER ${APP_ROLE} IN SCHEMA ${DB_SCHEMA}
  GRANT SELECT ON SEQUENCES TO ${RO_ROLE};

-- (optional) if your app uses functions and you want RO to execute them:
-- ALTER DEFAULT PRIVILEGES FOR USER ${APP_ROLE} IN SCHEMA ${DB_SCHEMA}
--   GRANT EXECUTE ON FUNCTIONS TO ${RO_ROLE};

-- (optional) set search_path for app role
ALTER ROLE ${APP_ROLE} IN DATABASE ${DB_NAME} SET search_path = ${DB_SCHEMA}, public;
ALTER ROLE ${RO_ROLE}  IN DATABASE ${DB_NAME} SET search_path = ${DB_SCHEMA}, public;

-- (optional) extensions (uncomment what you need)
-- CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;
-- CREATE EXTENSION IF NOT EXISTS "pgcrypto"   WITH SCHEMA public;
SQL

echo "[bootstrap] Done."
