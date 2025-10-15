#!/usr/bin/env bash
set -euo pipefail
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
echo ">> Stopping DB stack"
docker compose -f "${COMPOSE_FILE}" down -v
