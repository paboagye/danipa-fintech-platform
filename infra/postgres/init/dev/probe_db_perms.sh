#!/usr/bin/env bash
set -euo pipefail

container="${POSTGRES_CONTAINER:-danipa-postgres-dev}"
db="${DB_NAME:-danipa_fintech_db_dev}"
owner="${OWNER_ROLE:-danipa_owner_dev}"
app="${APP_ROLE:-danipa_app_dev}"
ro="${RO_ROLE:-danipa_ro_dev}"
migrator="${MIGRATOR_ROLE:-danipa_migrator_dev}"

# Defaults match bootstrap policy
write_schemas_default="fintech core payments momo webhooks ops"
ro_only_schemas_default="audit"

# Allow overrides via env/make, but ensure ro-only wins if overlap happens
raw_write="${APP_SCHEMAS:-$write_schemas_default}"
raw_ro="${RO_ONLY_SCHEMAS:-$ro_only_schemas_default}"

# --- De-duplicate with ro-only precedence ---
# Turn lists into newline sets
write_set="$(printf '%s\n' $raw_write | sed '/^$/d' | sort -u)"
ro_set="$(printf '%s\n' $raw_ro | sed '/^$/d' | sort -u)"

# Effective write = write_set minus ro_set
effective_write="$(comm -23 <(printf '%s\n' $write_set | sort) <(printf '%s\n' $ro_set | sort))"
effective_ro="$ro_set"

echo "[probe] container=${container} db=${db} owner=${owner} app=${app} ro=${ro} migrator=${migrator}"
echo "[probe] write-schemas (effective): ${effective_write:-<none>}"
echo "[probe] ro-only schemas (effective): ${effective_ro:-<none>}"

# --- preflight: container exists ---
if ! docker inspect --type container "$container" >/dev/null 2>&1; then
  echo "❌ container '$container' not found"; exit 2
fi

# quick psql helper
psqlc() {
  docker exec -i "$container" psql -v ON_ERROR_STOP=1 -X -q -U "$1" -d "$db" -c "$2"
}

# 0) migrator must not create arbitrary new schemas
if psqlc "$migrator" "CREATE SCHEMA _nope_${RANDOM};" 2>/dev/null; then
  echo "❌ Migrator was able to CREATE SCHEMA (should be denied)"; exit 3
else
  echo "✅ Migrator cannot CREATE SCHEMA (expected)"
fi

schema_exists() {
  local s="$1"
  psqlc "$owner" "SELECT 1 FROM pg_namespace WHERE nspname='${s}'" | grep -q 1
}

rc=0

test_write_schema() {
  local s="$1" t="${s}._perm_probe_${RANDOM}_$$_w"
  if ! schema_exists "$s"; then
    echo "⚠️  schema '${s}' does not exist; skipping"; rc=$(( rc | 4 )); return
  fi
  echo "[probe:${s}/write] creating ${t}"
  psqlc "$owner" "DROP TABLE IF EXISTS ${t};" || true
  psqlc "$migrator" "CREATE TABLE ${t}(id int);"
  echo "✅ [${s}] Migrator can CREATE TABLE"

  psqlc "$app" "INSERT INTO ${t} VALUES (1); SELECT * FROM ${t}; UPDATE ${t} SET id=2 WHERE id=1; DELETE FROM ${t} WHERE id=2;" >/dev/null
  echo "✅ [${s}] App can DML (INSERT/SELECT/UPDATE/DELETE)"

  psqlc "$ro" "INSERT INTO ${t} VALUES (1);" >/dev/null 2>&1 && { echo "❌ [${s}] RO could INSERT"; rc=$(( rc | 8 )); } || echo "✅ [${s}] RO cannot INSERT (expected)"
  psqlc "$ro" "SELECT 1 FROM ${t} LIMIT 1;" >/dev/null && echo "✅ [${s}] RO can SELECT" || { echo "❌ [${s}] RO cannot SELECT"; rc=$(( rc | 16 )); }

  psqlc "$owner" "DROP TABLE IF EXISTS ${t};" >/dev/null || true
  echo "✅ [${s}] cleanup done"
}

test_ro_schema() {
  local s="$1" t="${s}._perm_probe_${RANDOM}_$$_ro"
  if ! schema_exists "$s"; then
    echo "⚠️  schema '${s}' does not exist; skipping"; rc=$(( rc | 4 )); return
  fi
  echo "[probe:${s}/ro] creating ${t}"
  psqlc "$owner" "DROP TABLE IF EXISTS ${t};" || true
  psqlc "$migrator" "CREATE TABLE ${t}(id int);"
  echo "✅ [${s}] Migrator can CREATE TABLE"

  psqlc "$ro"  "SELECT 1 FROM ${t} LIMIT 1;" >/dev/null && echo "✅ [${s}] RO can SELECT" || { echo "❌ [${s}] RO cannot SELECT"; rc=$(( rc | 32 )); }
  psqlc "$ro"  "INSERT INTO ${t} VALUES (1);" >/dev/null 2>&1 && { echo "❌ [${s}] RO could INSERT"; rc=$(( rc | 64 )); } || echo "✅ [${s}] RO cannot INSERT (expected)"
  psqlc "$app" "INSERT INTO ${t} VALUES (1);" >/dev/null 2>&1 && { echo "❌ [${s}] App could INSERT (should be read-only)"; rc=$(( rc | 128 )); } || echo "✅ [${s}] App cannot INSERT (expected for read-only schema)"

  psqlc "$owner" "DROP TABLE IF EXISTS ${t};" >/dev/null || true
  echo "✅ [${s}] cleanup done"
}

for s in $effective_write; do test_write_schema "$s"; done
for s in $effective_ro; do test_ro_schema "$s"; done

if [ $rc -eq 0 ]; then
  echo "[probe] all checks passed 🎉"
else
  echo "[probe] completed with warnings/failures; rc=$rc"
fi
exit $rc
