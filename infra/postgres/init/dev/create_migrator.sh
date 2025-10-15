#!/usr/bin/env bash
set -euo pipefail

# --- Config (override via env if needed) ---
PG_CONTAINER="${PG_CONTAINER:-danipa-postgres-dev}"
DB_NAME="${DB_NAME:-danipa_fintech_db_dev}"
DB_SCHEMA="${DB_SCHEMA:-fintech}"

# DML group (already has SELECT/INSERT/UPDATE/DELETE via your bootstrap)
MIGRATOR_GROUP="${MIGRATOR_GROUP:-danipa_app}"

# Dedicated migrator login that may CREATE in the schema
MIGRATOR_ROLE="${MIGRATOR_ROLE:-danipa_migrator_dev}"
MIGRATOR_PASSWORD="${MIGRATOR_PASSWORD:-changeMeDevMigrator!}"

echo "[migrator] container=${PG_CONTAINER} db=${DB_NAME} schema=${DB_SCHEMA} role=${MIGRATOR_ROLE}"

# Helper: escape single quotes for SQL string literals
sql_escape() {
  # replace ' with ''
  printf "%s" "$1" | sed "s/'/''/g"
}

R_ESC="$(sql_escape "$MIGRATOR_ROLE")"
G_ESC="$(sql_escape "$MIGRATOR_GROUP")"
S_ESC="$(sql_escape "$DB_SCHEMA")"
P_ESC="$(sql_escape "$MIGRATOR_PASSWORD")"

# 1) Write a *fully rendered* SQL file inside the container (no psql vars)
docker exec -i "$PG_CONTAINER" bash -lc "cat > /tmp/create_migrator.sql" <<SQL
DO \$do\$
BEGIN
  -- Create/maintain the migrator login & membership
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${R_ESC}') THEN
    EXECUTE format(
      'CREATE ROLE %I LOGIN INHERIT IN ROLE %I PASSWORD %L',
      '${R_ESC}', '${G_ESC}', '${P_ESC}'
    );
  ELSE
    EXECUTE format('ALTER ROLE %I IN ROLE %I', '${R_ESC}', '${G_ESC}');
    EXECUTE format('ALTER ROLE %I PASSWORD %L', '${R_ESC}', '${P_ESC}');
  END IF;

  -- Lock schema CREATE to the migrator only (keep DML via group)
  EXECUTE format('REVOKE CREATE ON SCHEMA %I FROM PUBLIC', '${S_ESC}');
  EXECUTE format('REVOKE CREATE ON SCHEMA %I FROM %I',    '${S_ESC}', '${G_ESC}');
  EXECUTE format('GRANT  USAGE  ON SCHEMA %I TO %I',      '${S_ESC}', '${G_ESC}');
  EXECUTE format('GRANT  CREATE ON SCHEMA %I TO %I',      '${S_ESC}', '${R_ESC}');
END
\$do\$;
SQL

# 2) Execute it using the cluster owner from the container env
docker exec -it "$PG_CONTAINER" bash -lc '
  psql -v ON_ERROR_STOP=1 \
       -U "$POSTGRES_USER" \
       -d "'"$DB_NAME"'" \
       -h localhost \
       -f /tmp/create_migrator.sql
'

# 3) Quick checks
echo "[migrator] verify role:"
docker exec -it "$PG_CONTAINER" bash -lc \
  'psql -U "$POSTGRES_USER" -d "'"$DB_NAME"'" -h localhost -c "\du '"$MIGRATOR_ROLE"'"'

echo "[migrator] test CREATE as migrator (should succeed):"
docker exec -it "$PG_CONTAINER" bash -lc \
  'psql -U "'"$MIGRATOR_ROLE"'" -d "'"$DB_NAME"'" -h localhost \
     -c "CREATE TABLE IF NOT EXISTS '"$DB_SCHEMA"'._migrator_probe(id int);"'

echo "[migrator] test CREATE as app user (should fail):"
set +e
docker exec -it "$PG_CONTAINER" bash -lc \
  'psql -U danipa_app_dev -d "'"$DB_NAME"'" -h localhost \
     -c "CREATE TABLE '"$DB_SCHEMA"'._app_should_fail(id int);"'
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "✔ app user blocked from CREATE (expected)"
else
  echo "!! app user unexpectedly created a table — check grants"
fi

echo "[migrator] done."
