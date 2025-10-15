#!/usr/bin/env bash
set -euo pipefail

# If we're on the host, exec into the Postgres container and run this same script there.
if [ -z "${RUN_INSIDE_CONTAINER:-}" ]; then
  CONTAINER="${POSTGRES_CONTAINER:-danipa-postgres-dev}"
  exec docker exec -e RUN_INSIDE_CONTAINER=1 -it "$CONTAINER" bash -lc '/docker-entrypoint-initdb.d/010-bootstrap-db.sh'
fi

BOOT_ENV='/opt/pg-secrets/db-bootstrap.env'

echo "[init] waiting for ${BOOT_ENV}..."
for i in {1..30}; do [ -s "${BOOT_ENV}" ] && break; sleep 2; done
[ -s "${BOOT_ENV}" ] || { echo "❌ bootstrap env not found after 60s (${BOOT_ENV})"; exit 1; }

# Normalize CRLF → LF and source exporting keys
tmp_env="$(mktemp)"; tr -d '\r' < "${BOOT_ENV}" > "${tmp_env}"
set -a; . "${tmp_env}"; set +a; rm -f "${tmp_env}"

# Required from the rendered env
: "${ENVIRONMENT:?missing ENVIRONMENT}"
: "${DB_NAME:?missing DB_NAME}"
: "${DB_SCHEMA:?missing DB_SCHEMA}"        # primary app schema (e.g., fintech)
: "${APP_GROUP:?missing APP_GROUP}"        # e.g., danipa_app
: "${RO_GROUP:?missing RO_GROUP}"          # e.g., danipa_readonly
: "${APP_ROLE:?missing APP_ROLE}"          # e.g., danipa_app_dev
: "${RO_ROLE:?missing RO_ROLE}"            # e.g., danipa_ro_dev
: "${APP_ROLE_PASSWORD:?missing APP_ROLE_PASSWORD}"
: "${RO_ROLE_PASSWORD:?missing RO_ROLE_PASSWORD}"
: "${POSTGRES_USER:?missing POSTGRES_USER}"  # cluster owner inside container

# Migrator role name (env-scoped) + password
: "${MIGRATOR_ROLE:=danipa_migrator_${ENVIRONMENT}}"
upper_env="${ENVIRONMENT^^}"
pw_var="SPRING_FLYWAY_PLACEHOLDERS_DANIPA_MIGRATOR_${upper_env}_PASSWORD"
MIGRATOR_PASSWORD="${MIGRATOR_PASSWORD:-${!pw_var:-${SPRING_FLYWAY_PLACEHOLDERS_DANIPA_MIGRATOR_DEV_PASSWORD:-changeMeDevMigrator!}}}"

echo "[init] ENV=${ENVIRONMENT} DB=${DB_NAME} SCHEMA=${DB_SCHEMA} MIGRATOR=${MIGRATOR_ROLE}"
echo "[init] POSTGRES_USER=${POSTGRES_USER}"

# ------------------------------------------------------------
# Logical schema policy (overridable via env)
# ------------------------------------------------------------
APP_WRITE_SCHEMAS="${APP_WRITE_SCHEMAS:-"${DB_SCHEMA} core payments momo webhooks ops"}"
RO_ONLY_SCHEMAS="${RO_ONLY_SCHEMAS:-"audit"}"

# Turn space-separated lists into bash arrays
read -r -a SCHEMAS_DML <<< "${APP_WRITE_SCHEMAS}"
read -r -a SCHEMAS_READONLY <<< "${RO_ONLY_SCHEMAS}"

# --- Create DB if missing (connect to default "postgres") ---
psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d postgres -h localhost <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}') THEN
    EXECUTE 'CREATE DATABASE ${DB_NAME}';
  END IF;
END
\$\$;
SQL

# --- Roles, baseline grants on public ---
psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${DB_NAME}" -h localhost <<SQL
-- Group roles (NOLOGIN)
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${APP_GROUP}') THEN
    CREATE ROLE ${APP_GROUP} NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${RO_GROUP}') THEN
    CREATE ROLE ${RO_GROUP} NOINHERIT;
  END IF;
END
\$\$;

-- Env logins (inherit groups)
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${APP_ROLE}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN INHERIT IN ROLE ${APP_GROUP} PASSWORD %L', '${APP_ROLE}', '${APP_ROLE_PASSWORD}');
  ELSE
    EXECUTE format('ALTER ROLE %I PASSWORD %L', '${APP_ROLE}', '${APP_ROLE_PASSWORD}');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${RO_ROLE}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN INHERIT IN ROLE ${RO_GROUP} PASSWORD %L', '${RO_ROLE}', '${RO_ROLE_PASSWORD}');
  ELSE
    EXECUTE format('ALTER ROLE %I PASSWORD %L', '${RO_ROLE}', '${RO_ROLE_PASSWORD}');
  END IF;
END
\$\$;

-- Migrator login (separate credential)
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${MIGRATOR_ROLE}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN INHERIT PASSWORD %L', '${MIGRATOR_ROLE}', '${MIGRATOR_PASSWORD}');
  ELSE
    EXECUTE format('ALTER ROLE %I PASSWORD %L', '${MIGRATOR_ROLE}', '${MIGRATOR_PASSWORD}');
  END IF;
END
\$\$;

-- Ensure migrator is a member of the app group (idempotent)
GRANT ${APP_GROUP} TO ${MIGRATOR_ROLE};

-- Baseline safety on public schema
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SQL

echo "[init] roles/schemas/grants ✅"

# ---------------------------
# Helper functions
# ---------------------------
grant_for_schema() {
  local schema="$1"
  psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${DB_NAME}" -h localhost <<SQL
CREATE SCHEMA IF NOT EXISTS ${schema};
ALTER  SCHEMA ${schema} OWNER TO ${POSTGRES_USER};

REVOKE ALL    ON SCHEMA ${schema} FROM PUBLIC;
REVOKE CREATE ON SCHEMA ${schema} FROM ${APP_GROUP};
REVOKE CREATE ON SCHEMA ${schema} FROM ${RO_GROUP};

GRANT  USAGE  ON SCHEMA ${schema} TO ${APP_GROUP}, ${RO_GROUP};
GRANT  CREATE ON SCHEMA ${schema} TO ${MIGRATOR_ROLE};
SQL
}

# App-writable schemas (full DML for app, read-only for RO)
grant_dml_defaults() {
  local schema="$1"
  psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${DB_NAME}" -h localhost <<SQL
-- Existing objects
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA ${schema} TO ${APP_GROUP};
GRANT SELECT                           ON ALL TABLES    IN SCHEMA ${schema} TO ${RO_GROUP};
GRANT USAGE, SELECT, UPDATE            ON ALL SEQUENCES IN SCHEMA ${schema} TO ${APP_GROUP};
GRANT USAGE, SELECT                    ON ALL SEQUENCES IN SCHEMA ${schema} TO ${RO_GROUP};
GRANT EXECUTE                          ON ALL FUNCTIONS IN SCHEMA ${schema} TO ${APP_GROUP};

-- Default privileges for objects CREATED BY THE MIGRATOR in ${schema}
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATOR_ROLE} IN SCHEMA ${schema}
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO ${APP_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATOR_ROLE} IN SCHEMA ${schema}
  GRANT SELECT                         ON TABLES    TO ${RO_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATOR_ROLE} IN SCHEMA ${schema}
  GRANT USAGE, SELECT, UPDATE          ON SEQUENCES TO ${APP_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATOR_ROLE} IN SCHEMA ${schema}
  GRANT USAGE, SELECT                  ON SEQUENCES TO ${RO_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATOR_ROLE} IN SCHEMA ${schema}
  GRANT EXECUTE                        ON FUNCTIONS TO ${APP_GROUP};

-- Baseline defaults for objects CREATED BY THE CLUSTER OWNER
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA ${schema}
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO ${APP_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA ${schema}
  GRANT SELECT                         ON TABLES    TO ${RO_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA ${schema}
  GRANT USAGE, SELECT, UPDATE          ON SEQUENCES TO ${APP_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA ${schema}
  GRANT USAGE, SELECT                  ON SEQUENCES TO ${RO_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA ${schema}
  GRANT EXECUTE                        ON FUNCTIONS TO ${APP_GROUP};
SQL
}

# Read-only schemas (SELECT for app & ro; no app DML)
grant_readonly_defaults() {
  local schema="$1"
  psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${DB_NAME}" -h localhost <<SQL
-- Existing objects: SELECT for both app and ro (no DML for app)
GRANT SELECT ON ALL TABLES    IN SCHEMA ${schema} TO ${APP_GROUP}, ${RO_GROUP};
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ${schema} TO ${APP_GROUP}, ${RO_GROUP};
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ${schema} TO ${APP_GROUP};

-- Default privileges for objects CREATED BY THE MIGRATOR in ${schema}
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATOR_ROLE} IN SCHEMA ${schema}
  GRANT SELECT ON TABLES TO ${APP_GROUP}, ${RO_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATOR_ROLE} IN SCHEMA ${schema}
  GRANT USAGE, SELECT ON SEQUENCES TO ${APP_GROUP}, ${RO_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${MIGRATOR_ROLE} IN SCHEMA ${schema}
  GRANT EXECUTE ON FUNCTIONS TO ${APP_GROUP};

-- Baseline defaults for objects CREATED BY THE CLUSTER OWNER
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA ${schema}
  GRANT SELECT ON TABLES TO ${APP_GROUP}, ${RO_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA ${schema}
  GRANT USAGE, SELECT ON SEQUENCES TO ${APP_GROUP}, ${RO_GROUP};
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA ${schema}
  GRANT EXECUTE ON FUNCTIONS TO ${APP_GROUP};
SQL
}

# Apply policy across schemas
for s in "${SCHEMAS_DML[@]}"; do
  grant_for_schema "${s}"
  grant_dml_defaults "${s}"
done

for s in "${SCHEMAS_READONLY[@]}"; do
  grant_for_schema "${s}"
  grant_readonly_defaults "${s}"
done

echo "[init] schema privileges applied ✅"

# Optional: only apply truly bootstrap-only SQL here (e.g., extensions)
MIG_DIR="/docker-entrypoint-initdb.d/db-migration-common"
if [ -d "${MIG_DIR}" ] && [ -f "${MIG_DIR}/V2__core_extensions.sql" ]; then
  echo "[run-sql] applying V2__core_extensions.sql"
  psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${DB_NAME}" -h localhost -1 -f "${MIG_DIR}/V2__core_extensions.sql"
fi

echo "[init] bootstrap completed"
