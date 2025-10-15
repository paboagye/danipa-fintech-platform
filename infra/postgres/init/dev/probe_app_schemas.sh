#!/usr/bin/env bash
set -euo pipefail

# === Config (override via env) ===
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-danipa-postgres-dev}"
DB_NAME="${DB_NAME:-danipa_fintech_db_dev}"

OWNER_ROLE="${OWNER_ROLE:-danipa_owner_dev}"
APP_ROLE="${APP_ROLE:-danipa_app_dev}"
RO_ROLE="${RO_ROLE:-danipa_ro_dev}"
MIGRATOR_ROLE="${MIGRATOR_ROLE:-danipa_migrator_dev}"

# App-writable schemas vs read-only schemas
APP_WRITE_SCHEMAS="${APP_WRITE_SCHEMAS:-fintech core payments momo webhooks ops}"
RO_ONLY_SCHEMAS="${RO_ONLY_SCHEMAS:-audit}"

say()  { printf "%b\n" "$*"; }
ok()   { say "✅ $*"; }
warn() { say "⚠️  $*"; }
fail() { say "❌ $*"; exit 1; }

psql_as() {
  local role="$1"; shift
  docker exec -i "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$role" -d "$DB_NAME" -c "$*"
}

schema_exists() {
  local sc="$1"
  psql_as "$OWNER_ROLE" "SELECT 1 FROM pg_namespace WHERE nspname = '$sc';" | grep -q 1
}

cleanup_table() {
  local schema="$1" tbl="$2"
  psql_as "$OWNER_ROLE" "DROP TABLE IF EXISTS ${schema}.${tbl};" >/dev/null || true
}

say "[probe] container=$POSTGRES_CONTAINER db=$DB_NAME owner=$OWNER_ROLE app=$APP_ROLE ro=$RO_ROLE migrator=$MIGRATOR_ROLE"
say "[probe] write-schemas: $APP_WRITE_SCHEMAS"
say "[probe] ro-only schemas: $RO_ONLY_SCHEMAS"

# Migrator must NOT be able to create arbitrary schemas
if psql_as "$MIGRATOR_ROLE" "CREATE SCHEMA nope_should_fail;" 2>/dev/null; then
  fail "Migrator unexpectedly created a new schema"
else
  ok "Migrator cannot CREATE SCHEMA (expected)"
fi

probe_schema() {
  local SC="$1" MODE="$2" ; # MODE = write or ro
  if ! schema_exists "$SC"; then
    warn "schema '$SC' does not exist; skipping"
    return 0
  fi

  local TBL="_perm_probe_$(date +%s)_$RANDOM"
  say "[probe:$SC/$MODE] creating ${SC}.${TBL}"
  cleanup_table "$SC" "$TBL"

  # Migrator can create
  psql_as "$MIGRATOR_ROLE" "CREATE TABLE ${SC}.${TBL}(id int primary key);"
  ok "[$SC] Migrator can CREATE TABLE"

  if [ "$MODE" = "write" ]; then
    # App can DML
    psql_as "$APP_ROLE" "INSERT INTO ${SC}.${TBL} VALUES (1);"
    psql_as "$APP_ROLE" "SELECT * FROM ${SC}.${TBL};" >/dev/null
    psql_as "$APP_ROLE" "UPDATE ${SC}.${TBL} SET id = 2 WHERE id = 1;"
    psql_as "$APP_ROLE" "DELETE FROM ${SC}.${TBL} WHERE id = 2;"
    ok "[$SC] App can DML (INSERT/SELECT/UPDATE/DELETE)"

    # RO can SELECT, cannot INSERT
    psql_as "$APP_ROLE" "INSERT INTO ${SC}.${TBL} VALUES (3);"
    psql_as "$RO_ROLE"  "SELECT * FROM ${SC}.${TBL};" >/dev/null && ok "[$SC] RO can SELECT"
    if psql_as "$RO_ROLE" "INSERT INTO ${SC}.${TBL} VALUES (4);" 2>/dev/null; then
      cleanup_table "$SC" "$TBL"; fail "[$SC] RO was able to INSERT (should be read-only)"
    else
      ok "[$SC] RO cannot INSERT (expected)"
    fi
  else
    # ro-only mode: App should not be able to INSERT
    psql_as "$RO_ROLE" "SELECT 1;" >/dev/null # ensure role works
    # Both can SELECT; neither should INSERT
    psql_as "$RO_ROLE"  "SELECT * FROM ${SC}.${TBL};" >/dev/null && ok "[$SC] RO can SELECT"
    if psql_as "$RO_ROLE" "INSERT INTO ${SC}.${TBL} VALUES (1);" 2>/dev/null; then
      cleanup_table "$SC" "$TBL"; fail "[$SC] RO was able to INSERT (should be read-only)"
    else
      ok "[$SC] RO cannot INSERT (expected)"
    fi
    if psql_as "$APP_ROLE" "INSERT INTO ${SC}.${TBL} VALUES (2);" 2>/dev/null; then
      cleanup_table "$SC" "$TBL"; fail "[$SC] App was able to INSERT (should be read-only here)"
    else
      ok "[$SC] App cannot INSERT (expected for read-only schema)"
    fi
  fi

  cleanup_table "$SC" "$TBL"
  ok "[$SC] cleanup done"
}

for sc in $APP_WRITE_SCHEMAS; do probe_schema "$sc" write; done
for sc in $RO_ONLY_SCHEMAS;  do probe_schema "$sc" ro;    done

say "[probe] all checks passed 🎉"
