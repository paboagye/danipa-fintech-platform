#!/usr/bin/env bash
set -euo pipefail

# ==== Tune these if your compose or domains differ ====
SERVICE="eureka-server"                       # docker compose service name
CONTAINER="danipa-eureka-server"              # container_name
HOST_LOGDIR="logs/eureka"                     # host-side folder for captured logs

# Internal health: Eureka usually on 8761 (actuator still /actuator/health)
HEALTH_URL_INTERNAL="${HEALTH_URL_INTERNAL:-http://127.0.0.1:8761/actuator/health}"

# Optional external probe via Traefik/HTTPS (if you expose it)
HEALTH_URL_EXTERNAL="${HEALTH_URL_EXTERNAL:-https://eureka.local.danipa.com/actuator/health}"
CA_CERT="${CA_CERT:-infra/vault/tls/root_ca.crt}"

# Optional extra (JWT) health if you have a gated endpoint
HEALTH_GATED_URL="${HEALTH_GATED_URL:-http://127.0.0.1:8761/actuator/health-gated}"
BEARER_TOKEN="${BEARER_TOKEN:-}"              # set to run gated check

# In-app rolling log inside the container (adjust to your app name if needed)
APPFILE="/app/logs/danipa-eureka-server/danipa-eureka-server.log"

echo "== Step 0: timestamp for fresh docker logs =="
SINCE="$(date -Is)"

echo "== Step 1: stop service (ignore if not running) =="
docker compose stop "$SERVICE" >/dev/null 2>&1 || true

echo "== Step 2: wipe host log directory (keep folder) =="
mkdir -p "$HOST_LOGDIR"
find "$HOST_LOGDIR" -maxdepth 1 -type f -print -delete || true

echo "== Step 3: start service =="
docker compose up -d "$SERVICE"

echo "== Step 4: clear in-app rolling log (if not bind-mounted) =="
docker exec "$CONTAINER" sh -lc 'rm -f /app/logs/danipa-eureka-server/* || true' || true

echo "== Step 5: wait for INTERNAL health (90s max) =="
ok=false
for i in {1..30}; do
  if curl -fsS "$HEALTH_URL_INTERNAL" >/dev/null 2>&1; then
    echo "Internal health is UP."
    ok=true
    break
  fi
  sleep 3
done

if [ "$ok" != true ]; then
  echo "❌ Internal health did not become UP within timeout."
  echo "== Tailing container logs =="
  docker logs --since "$SINCE" "$CONTAINER" | tail -n 200 || true
  exit 1
fi

# Optional: external HTTPS probe via Traefik (uses Step root CA)
if [ -f "$CA_CERT" ]; then
  echo "== Step 6: external HTTPS health via Traefik =="
  if curl -fsS --cacert "$CA_CERT" "$HEALTH_URL_EXTERNAL" >/dev/null 2>&1; then
    echo "External HTTPS health is UP."
  else
    echo "⚠️ External HTTPS health check failed (maybe DNS/Traefik/bootstrap timing)."
  fi
else
  echo "⚠️ Skipping external HTTPS check: CA cert not found at $CA_CERT"
fi

# Optional: gated health if BEARER_TOKEN provided
if [ -n "$BEARER_TOKEN" ]; then
  echo "== Step 7: gated health (JWT) =="
  if curl -fsS -H "Authorization: Bearer $BEARER_TOKEN" "$HEALTH_GATED_URL" >/dev/null 2>&1; then
    echo "Gated health is OK (token accepted)."
  else
    echo "⚠️ Gated health failed — token may be missing scope/role or audience."
  fi
fi

echo "== Step 8: capture fresh logs to $HOST_LOGDIR =="
docker logs --since "$SINCE" "$CONTAINER" > "$HOST_LOGDIR/container.stdout.fresh.log" 2>&1 || true

if docker exec "$CONTAINER" sh -lc "[ -f $APPFILE ]"; then
  docker exec "$CONTAINER" sh -lc "tail -n +1 $APPFILE" > "$HOST_LOGDIR/app.log.fresh.log" || true
else
  echo "(no in-app logfile yet)" > "$HOST_LOGDIR/app.log.fresh.log"
fi

echo "== Done =="
echo "  - $HOST_LOGDIR/container.stdout.fresh.log"
echo "  - $HOST_LOGDIR/app.log.fresh.log"
