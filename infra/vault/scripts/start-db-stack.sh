#!/usr/bin/env bash
set -euo pipefail

APP_ENV="${APP_ENV:-dev}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

echo ">> Starting DB stack for ${APP_ENV}"
docker compose -f "${COMPOSE_FILE}" up -d postgres vault step-ca

echo ">> Waiting for Postgres to be healthy..."
TRIES=45; until docker inspect --format='{{.State.Health.Status}}' $(docker compose ps -q postgres) | grep -q healthy; do
  ((TRIES--)) || { echo "Postgres not healthy in time"; exit 1; }
  sleep 2
done

echo ">> (Optional) Issue Vault server certs & reload per guide"
# make vault-cert CN=vault.${APP_ENV}.local.danipa.com SANS="vault.${APP_ENV}.local.danipa.com vault localhost 127.0.0.1"
# make vault-unseal

echo ">> Bootstrap DB (idempotent)"
PGHOST=localhost PGPORT=55432 PGUSER=postgres PGPASSWORD=postgres \
infra/postgres/init/${APP_ENV}/010-bootstrap-db.sh

echo ">> Run probe"
make probe-db-perms APP_ENV=${APP_ENV}
