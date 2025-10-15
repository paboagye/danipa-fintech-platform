#!/usr/bin/env bash
set -euo pipefail

DB=${DB_NAME:-danipa_fintech_db_dev}
OWNER=${OWNER_ROLE:-danipa_owner_dev}
APP=${APP_ROLE:-danipa_app_dev}
RO=${RO_ROLE:-danipa_ro_dev}
MIG=${MIGRATOR_ROLE:-danipa_migrator_dev}
CONTAINER=${POSTGRES_CONTAINER:-danipa-postgres-dev}

run() {
  docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U "$1" -d "$DB" -tA -c "$2"
}

ok() { echo "✅ $1"; }
bad(){ echo "❌ $1"; exit 1; }

echo "[probe] using DB=$DB owner=$OWNER app=$APP ro=$RO migrator=$MIG"

# 1) Migrator cannot create random schemas (must fail)
if run "$MIG" "CREATE SCHEMA _should_fail_probe;" 2>/dev/null; then
  bad "Migrator was able to CREATE SCHEMA (should be denied)"
else
  ok "Migrator cannot CREATE SCHEMA (expected)"
fi

# 2) Migrator can create table in app schema
run "$MIG" "DROP TABLE IF EXISTS fintech._perm_test;"
run "$MIG" "CREATE TABLE fintech._perm_test(id int);"
ok "Migrator can CREATE TABLE in fintech"

# 3) App can DML; RO can only select
run "$APP" "INSERT INTO fintech._perm_test VALUES (1);"
rows="$(run "$RO" "SELECT count(*) FROM fintech._perm_test;")"
[ "$rows" = "1" ] && ok "RO can SELECT data" || bad "RO failed to SELECT"

if run "$RO" "INSERT INTO fintech._perm_test VALUES (2);" 2>/dev/null; then
  bad "RO was able to INSERT (should be denied)"
else
  ok "RO cannot INSERT (expected)"
fi

# 4) Cleanup
run "$OWNER" "DROP TABLE IF EXISTS fintech._perm_test;"
ok "Cleanup done"

echo "[probe] all checks passed"
