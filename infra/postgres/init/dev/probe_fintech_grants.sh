#!/usr/bin/env bash
set -euo pipefail

# ---- defaults (override via env) ----
PG_CONTAINER="${PG_CONTAINER:-danipa-postgres-dev}"
DB_NAME="${DB_NAME:-danipa_fintech_db_dev}"
DB_USER="${DB_USER:-danipa_owner_dev}"
SCHEMA="${SCHEMA:-fintech}"
ROLEPREFIX="${ROLEPREFIX:-danipa_%}"
GROUP_APP="${GROUP_APP:-danipa_app}"
GROUP_RO="${GROUP_RO:-danipa_readonly}"
SQL_SRC_PATH="${SQL_SRC_PATH:-/docker-entrypoint-initdb.d/probe_fintech_grants.sql}"
SQL_TMP_PATH="/tmp/probe_fintech_grants.sql"

echo "[*] Running fintech privilege probe..."
echo "    container=${PG_CONTAINER} db=${DB_NAME} user=${DB_USER} schema=${SCHEMA}"

docker exec -i "${PG_CONTAINER}" bash -lc "
  # copy SQL to a writable location and normalize CRLF -> LF
  if [ -f '${SQL_SRC_PATH}' ]; then
    tr -d '\r' < '${SQL_SRC_PATH}' > '${SQL_TMP_PATH}'
  else
    echo 'ERROR: ${SQL_SRC_PATH} not found' >&2
    exit 1
  fi

  psql -v ON_ERROR_STOP=1 -U '${DB_USER}' -d '${DB_NAME}' -h localhost \
    -v schema='${SCHEMA}' \
    -v roleprefix='${ROLEPREFIX}' \
    -v group_app='${GROUP_APP}' \
    -v group_ro='${GROUP_RO}' \
    -f '${SQL_TMP_PATH}'
"
