#!/usr/bin/env bash
set -euo pipefail

# ------- Inputs (adjust only if yours differ) -------
: "${VAULT_ADDR:=https://vault.local.danipa.com}"
: "${VAULT_CACERT:=infra/vault/tls/root_ca.crt}"
: "${MOUNT:=secret}"
: "${SEEDS_DIR:=infra/vault/seeds}"
: "${ENV:=dev}"                         # dev | staging | prod

# A Vault token allowed to read everything (root/admin or similar)
export VAULT_TOKEN="${VAULT_TOKEN:-$(jq -r .root_token infra/vault/keys/vault-keys.json)}"

# Keycloak client that has aud including danipa-config-server
KC_REALM_URL="http://localhost:8082/realms/danipa/protocol/openid-connect/token"
KC_CLIENT_ID="danipa-fintech-service"
KC_CLIENT_SECRET="4rwpx9IBEPGVttGDAoyVVrO6zGObwlfq"

# ------- Helpers -------
auth=(-H "X-Vault-Token: $VAULT_TOKEN")
tls=(--cacert "$VAULT_CACERT")

jok(){ jq -r 'if . == true or . == "OK" then "OK" else "FAIL" end'; }
hr(){ printf '%*s\n' 80 | tr ' ' -; }

echo "== Vault @ $VAULT_ADDR  (mount: $MOUNT)"; hr

# 1) KV engine is v2
ver=$(curl -sS "${tls[@]}" "${auth[@]}" "$VAULT_ADDR/v1/sys/mounts" | jq -r '."'"$MOUNT"'/".options.version // ""')
printf "KV engine version at '%s': %s\n" "$MOUNT" "${ver:-<none>}"
test "$ver" = "2" || { echo "FAIL: $MOUNT is not kv v2"; exit 1; }

# 2) Composite doc exists and has all required fields
RAW=$(curl -sS "${tls[@]}" "${auth[@]}" "$VAULT_ADDR/v1/$MOUNT/data/danipa-config-server,composite")
echo "$RAW" | jq -e '.data.data' >/tmp/composite.json

printf "Composite shape: "
jq -r '
  def asnum: if type=="number" then . else (try tonumber catch 0) end;
  [
    .["spring.cloud.config.server.composite[0].type"] == "vault",
    (.["spring.cloud.config.server.composite[0].host"] // ""       | tostring | length) > 0,
    (.["spring.cloud.config.server.composite[0].port"] // 0         | asnum)   > 0,
    .["spring.cloud.config.server.composite[0].scheme"] == "https",
    .["spring.cloud.config.server.composite[0].backend"] == "secret",
    (.["spring.cloud.config.server.composite[0].defaultKey"] // ""  | tostring | startswith("danipa/")),
    (.["spring.cloud.config.server.composite[0].kvVersion"] // 0    | asnum)   == 2,
    (.["spring.cloud.config.server.composite[0].profileSeparator"] // "" | tostring) == ",",
    (.["spring.cloud.config.server.composite[0].token"] // ""       | tostring | length) > 0,

    .["spring.cloud.config.server.composite[1].type"] == "git",
    (.["spring.cloud.config.server.composite[1].uri"] // ""         | tostring | startswith("https://")),
    .["spring.cloud.config.server.composite[1].username"] == "x-access-token",
    (.["spring.cloud.config.server.composite[1].password"] // ""    | tostring | length) > 0,
    (.["spring.cloud.config.server.composite[1].default-label"] // "" | tostring | length) > 0,
    (.["spring.cloud.config.server.composite[1].searchPaths"] // ""  | tostring) == "{application}"
  ] | all
' /tmp/composite.json | jok

# 3) Extract composite token
COMPOSITE_TOKEN=$(jq -r '."spring.cloud.config.server.composite[0].token"' /tmp/composite.json)
printf "Composite token prefix: %s…\n" "$(printf %s "$COMPOSITE_TOKEN" | cut -c1-6)"

# 4) Capabilities check for the composite token (should be READ on all below, including application/composite)
echo "Capabilities (composite token)"; hr
CAPS_REQ=$(jq -nc --arg m "$MOUNT" --arg e "$ENV" '
  {paths:[
    ($m+"/data/application"),
    ($m+"/data/application,"+$e),
    ($m+"/data/application/composite"),
    ($m+"/data/danipa/config"),
    ($m+"/data/danipa/config,"+$e),
    ($m+"/data/danipa-fintech-service"),
    ($m+"/data/danipa-fintech-service,"+$e),
    ($m+"/data/danipa-eureka-server"),
    ($m+"/data/danipa-eureka-server,"+$e)
  ]}')
curl -sS "${tls[@]}" -H "X-Vault-Token: $COMPOSITE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$CAPS_REQ" "$VAULT_ADDR/v1/sys/capabilities-self" | jq .

# Also do quick data reads (reports OK/NOT_FOUND/permission denied)
echo; echo "Data reads (composite token)"; hr
for p in \
  application \
  application,"$ENV" \
  application/composite \
  danipa/config \
  danipa/config,"$ENV" \
  danipa-fintech-service \
  danipa-fintech-service,"$ENV" \
  danipa-eureka-server \
  danipa-eureka-server,"$ENV"
do
  printf "%-40s -> " "$p"
  curl -sS "${tls[@]}" -H "X-Vault-Token: $COMPOSITE_TOKEN" \
    "$VAULT_ADDR/v1/$MOUNT/data/$p" | jq -r 'if .data and .data.data then "OK" else (."errors"[0] // "NOT_FOUND") end'
done

# 5) Seed file token must match Vault token
SEED_FILE="$SEEDS_DIR/$ENV.json"
echo; printf "Seed file token matches Vault token: "
jq -r --arg tok "$COMPOSITE_TOKEN" '
  .paths["danipa-config-server,composite"]["spring.cloud.config.server.composite[0].token"] == $tok
' "$SEED_FILE" | jok

# 6) Config Server endpoint — expect:
#    - 401 for unauthenticated localhost URL
#    - 200 (Environment JSON) for authenticated request to internal name 'config-server'
echo; echo "Config Server unauthenticated (expect 401 or 403, not 500)"; hr
curl -sk -D- https://127.0.0.1:8088/danipa-fintech-service/"$ENV" | head -n 20

echo; echo "Fetch Keycloak token and call Config Server (expect 200)"; hr
RAW_TOKEN_JSON=$(curl -s \
  -d "client_id=$KC_CLIENT_ID" \
  -d "client_secret=$KC_CLIENT_SECRET" \
  -d "grant_type=client_credentials" \
  "$KC_REALM_URL")

ACCESS_TOKEN=$(printf '%s' "$RAW_TOKEN_JSON" | tr -d '\n' | sed -E 's/.*"access_token":"([^"]+)".*/\1/')
if [ -z "${ACCESS_TOKEN:-}" ]; then
  echo "FAIL: could not obtain Keycloak access token"; exit 2
fi

curl -sk -D- -H "Authorization: Bearer $ACCESS_TOKEN" \
  https://config-server:8088/danipa-fintech-service/"$ENV" | head -n 40
