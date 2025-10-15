#!/usr/bin/env bash
set -euo pipefail

PG_DEV_CTN="danipa-postgres-dev"
: "${POSTGRES_USER_DEV:=danipa_owner_dev}"
: "${POSTGRES_DB_DEV:=danipa_fintech_db_dev}"

echo "🔎 Checking DB & user…"
docker exec -it "$PG_DEV_CTN" psql -U "$POSTGRES_USER_DEV" -d "$POSTGRES_DB_DEV" -c "SELECT current_database(), current_user;"

echo "🔎 Checking Flyway history…"
docker exec -it "$PG_DEV_CTN" psql -U "$POSTGRES_USER_DEV" -d "$POSTGRES_DB_DEV" -c "TABLE flyway_schema_history;"
