#!/usr/bin/env bash
set -euo pipefail

# Services (container names)
SVCS=(danipa-fintech-service danipa-config-server danipa-eureka-server)

# Host log dirs (relative to repo root)
HOST_LOGS=(./logs/fintech ./logs/config ./logs/eureka)

CLEAN_HOST="${1:-}"   # pass --host to also clear host-side logs

echo "=== [1/3] Cleaning logs INSIDE containers ==="
for svc in "${SVCS[@]}"; do
  echo "-> $svc"
  docker exec -it "$svc" sh -lc 'rm -f /app/logs/*/*.log /app/logs/*/*.gz 2>/dev/null || true' || true
done

if [[ "$CLEAN_HOST" == "--host" ]]; then
  echo "=== [1a] Cleaning logs on HOST filesystem ==="
  for d in "${HOST_LOGS[@]}"; do
    echo "-> $d"
    rm -f "$d"/*.log "$d"/*.gz 2>/dev/null || true
  done
fi

echo "=== [2/3] Restarting target containers ==="
docker compose restart fintech-service config-server eureka-server

echo "=== [3/3] Verifying Kafka bootstrap in Eureka logs ==="
# give Eureka a moment to start logging
sleep 6
echo "--- Lines mentioning Kafka bootstrap (expect kafka:9092) ---"
docker logs danipa-eureka-server 2>&1 | grep -iE 'bootstrap\.servers|kafka.*bootstrap' || true

echo "Done."
