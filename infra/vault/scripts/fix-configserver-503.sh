#!/usr/bin/env bash
set -euo pipefail

# ---- Settings you can override via env ----
VAULT_HOST_ADDR="${VAULT_HOST_ADDR:-http://127.0.0.1:18300}"   # host port-forward to Vault
VAULT_MOUNT="${VAULT_MOUNT:-secret}"
ENV_NAME="${ENV_NAME:-dev}"
CONFIG_APP="${CONFIG_APP:-danipa-config-server}"
ROLE_NAME="config-server-role-${ENV_NAME}"
POLICY_NAME="read-config-server-secrets-${ENV_NAME}"

ROOT_TOKEN="${ROOT_TOKEN:-$(jq -r .root_token infra/vault/keys/vault-keys.json)}"
[ -z "$ROOT_TOKEN" -o "$ROOT_TOKEN" = "null" ] && { echo "!! Could not load root token"; exit 2; }

ah() { printf '%s' "-H" "X-Vault-Token: $1"; }  # auth header helper

echo "==> Checking current config-server Vault token + policies"
TOKEN_IN_USE="$(docker compose exec config-server sh -lc 'head -n1 /opt/secrets/.vault-token 2>/dev/null' | tr -d '\r')"
if [ -z "$TOKEN_IN_USE" ]; then
  echo "!! No /opt/secrets/.vault-token inside config-server. Restarting agent to render it..."
  docker compose restart config-server-agent >/dev/null
  sleep 2
  TOKEN_IN_USE="$(docker compose exec config-server sh -lc 'head -n1 /opt/secrets/.vault-token 2>/dev/null' | tr -d '\r')"
fi

if [ -n "$TOKEN_IN_USE" ]; then
  curl -fsS "$(ah "$TOKEN_IN_USE")" \
    "$VAULT_HOST_ADDR/v1/auth/token/lookup-self" | jq -r '
      "  display_name=\(.data.display_name)",
      "  policies=\(.data.policies|join(","))",
      "  meta.role_name=\(.data.meta.role_name // "<none>")",
      "  ttl=\(.data.ttl)"'
else
  echo "!! Still no token available; continuing with policy fix (agent will pick up after restart)."
fi

echo
echo "==> Upserting policy '$POLICY_NAME' (includes health-probe paths)"
read -r -d '' POLICY_HCL <<HCL
path "$VAULT_MOUNT/data/${CONFIG_APP},${ENV_NAME}" { capabilities = ["read"] }
path "$VAULT_MOUNT/data/${CONFIG_APP}/*"          { capabilities = ["read"] }
path "$VAULT_MOUNT/metadata/${CONFIG_APP}"        { capabilities = ["list"] }
path "$VAULT_MOUNT/metadata/${CONFIG_APP}/*"      { capabilities = ["list"] }

# standard config paths the server reads
path "$VAULT_MOUNT/data/danipa/config,${ENV_NAME}" { capabilities = ["read"] }
path "$VAULT_MOUNT/data/application"               { capabilities = ["read"] }
path "$VAULT_MOUNT/data/application/composite"     { capabilities = ["read"] }
path "$VAULT_MOUNT/metadata/application"           { capabilities = ["list"] }
path "$VAULT_MOUNT/metadata/application/*"         { capabilities = ["list"] }

# health probe key (this is what the actuator checks)
path "$VAULT_MOUNT/data/app"         { capabilities = ["read"] }
path "$VAULT_MOUNT/metadata/app"     { capabilities = ["read","list"] }

# allow reading service profiles referenced by the platform
path "$VAULT_MOUNT/data/danipa-eureka-server,${ENV_NAME}"     { capabilities = ["read"] }
path "$VAULT_MOUNT/data/danipa-fintech-service,${ENV_NAME}"   { capabilities = ["read"] }
HCL

PAYLOAD="$(python3 -c 'import sys,json;print(json.dumps({"policy":sys.stdin.read()}))' <<<"$POLICY_HCL")"
# Try modern endpoint first, fall back if needed
code="$(curl -s -o /tmp/pol.out -w '%{http_code}' -X PUT \
       -H 'Content-Type: application/json' "$(ah "$ROOT_TOKEN")" \
       "$VAULT_HOST_ADDR/v1/sys/policies/acl/$POLICY_NAME" -d "$PAYLOAD")"
if [ "$code" != "200" ] && [ "$code" != "204" ]; then
  code="$(curl -s -o /tmp/pol.out -w '%{http_code}' -X PUT \
         -H 'Content-Type: application/json' "$(ah "$ROOT_TOKEN")" \
         "$VAULT_HOST_ADDR/v1/sys/policy/$POLICY_NAME" -d "$PAYLOAD")"
  [ "$code" = "200" -o "$code" = "204" ] || { echo "!! policy upsert failed ($code)"; cat /tmp/pol.out; exit 1; }
fi
echo "   policy upserted."

echo
echo "==> Seeding health-probe key ($VAULT_MOUNT/data/app)"
curl -fsS -X POST -H 'Content-Type: application/json' "$(ah "$ROOT_TOKEN")" \
  "$VAULT_HOST_ADDR/v1/$VAULT_MOUNT/data/app" \
  -d '{"data":{"ok":"true"}}' >/dev/null
echo "   seeded."

echo
echo "==> Restarting agent + config-server and waiting for /actuator/health UP"
docker compose restart config-server-agent >/dev/null
docker compose restart config-server >/dev/null

# poll health
for i in $(seq 1 60); do
  body="$(docker compose exec config-server sh -lc 'curl -fsS http://127.0.0.1:8088/actuator/health || true')"
  if jq -e '.status=="UP"' >/dev/null 2>&1 <<<"$body"; then
    echo "   HEALTH: UP"; break
  fi
  [ "$i" = 60 ] && { echo "!! HEALTH still not UP"; echo "$body"; exit 1; }
  sleep 1
done

echo
echo "==> Re-enable JWT for application/composite (secure the endpoints again)"
curl -fsS -H 'Content-Type: application/json' "$(ah "$ROOT_TOKEN")" \
  -X POST "$VAULT_HOST_ADDR/v1/$VAULT_MOUNT/data/application/composite" \
  -d '{"data":{"security.jwt.enabled":"true",
               "spring.security.oauth2.resourceserver.jwt.issuer-uri":"http://keycloak:8080/realms/danipa",
               "spring.security.oauth2.resourceserver.jwt.jwk-set-uri":"http://keycloak:8080/realms/danipa/protocol/openid-connect/certs"}}' >/dev/null

docker compose restart config-server >/dev/null
echo "   config-server restarted with JWT=TRUE"

echo
echo "==> Bring up Eureka and Fintech"
docker compose up -d eureka-server fintech-service

echo
echo "==> Quick tips"
cat <<'TXT'
- Config Server health:    curl -fsS http://127.0.0.1:8088/actuator/health | jq .
- Config (now secured):    curl -i http://127.0.0.1:8088/danipa-fintech-service/dev   # expect 401 without token
- Eureka:                  curl -fsS http://127.0.0.1:8761/actuator/health | jq .      # adjust port if different
- Fintech service:         curl -fsS http://127.0.0.1:8080/actuator/health | jq .      # adjust port if different
TXT
