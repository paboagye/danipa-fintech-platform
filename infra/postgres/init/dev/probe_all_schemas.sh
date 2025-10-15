#!/usr/bin/env bash
set -euo pipefail

# ---- defaults (override via env) ----
PG_CONTAINER="${PG_CONTAINER:-danipa-postgres-dev}"
DB_NAME="${DB_NAME:-danipa_fintech_db_dev}"
DB_USER="${DB_USER:-danipa_owner_dev}"
ROLEPREFIX="${ROLEPREFIX:-danipa_%}"
GROUP_APP="${GROUP_APP:-danipa_app}"
GROUP_RO="${GROUP_RO:-danipa_readonly}"
SQL_FILE="${SQL_FILE:-infra/postgres/init/dev/probe_all_schemas.sql}"
# Optional: restrict to specific schemas (comma+space separated), e.g. "fintech" or "fintech, public"
ONLY_SCHEMAS="${ONLY_SCHEMAS:-}"

echo "[*] Running all-schema privilege probe..."
echo "    container=${PG_CONTAINER} db=${DB_NAME} user=${DB_USER}"

mkdir -p out 2>/dev/null || true

# Build psql -v args
PSQL_VARS=(-v ON_ERROR_STOP=1
           -v roleprefix="${ROLEPREFIX}"
           -v group_app="${GROUP_APP}"
           -v group_ro="${GROUP_RO}")
if [[ -n "${ONLY_SCHEMAS}" ]]; then
  PSQL_VARS+=(-v only_schemas="${ONLY_SCHEMAS}")
fi

# Run SQL via stdin (so you don't have to mount into container)
docker exec -i "${PG_CONTAINER}" bash -lc "
  psql -U '${DB_USER}' -d '${DB_NAME}' -h localhost \
       ${PSQL_VARS[*]} \
       -f -
" < "${SQL_FILE}"
