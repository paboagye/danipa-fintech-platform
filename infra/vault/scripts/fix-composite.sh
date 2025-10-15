#!/usr/bin/env bash
set -euo pipefail

# --- Vault basics (KV v2 @ mount "secret") ---
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18300}"
TOKEN="$(jq -r '.root_token' infra/vault/keys/vault-keys.json)"
HDR=(-H "X-Vault-Token: $TOKEN" -H 'Content-Type: application/json')

# --- Desired endpoint for config-server inside Docker ---
TARGET_HOST="vault"
TARGET_SCHEME="http"
TARGET_PORT="8200"

# --- Candidate KV v2 data endpoints to check/patch ---
PATHS=(
  "secret/data/application/composite"
  "secret/data/application,composite"
  "secret/data/danipa-config-server"
  "secret/data/danipa-config-server,dev"
  "secret/data/danipa-config-server/dev"
)

kv_get() { curl -s "${HDR[@]::1}" "$VAULT_ADDR/v1/$1"; }
kv_put() { # $1=path  $2=json object for .data
  curl -s -X PUT "${HDR[@]}" "$VAULT_ADDR/v1/$1" -d "{\"data\":$2}" >/dev/null
}

show_keys() {
  local p="$1"
  kv_get "$p" | jq -r '
    .data.data // {} |
    {
      host: .["spring.cloud.config.server.composite[0].host"],
      scheme: .["spring.cloud.config.server.composite[0].scheme"],
      port: .["spring.cloud.config.server.composite[0].port"]
    }'
}

patch_to_vault() {
  local p="$1"
  local cur updated
  cur="$(kv_get "$p" | jq -c '.data.data // {}')"
  updated="$(jq -c --arg h "$TARGET_HOST" --arg s "$TARGET_SCHEME" --arg prt "$TARGET_PORT" '
      .["spring.cloud.config.server.composite[0].host"]=$h
    | .["spring.cloud.config.server.composite[0].scheme"]=$s
    | .["spring.cloud.config.server.composite[0].port"]=$prt
  ' <<<"$cur")"
  kv_put "$p" "$updated"
}

delete_composite_keys() {
  local p="$1"
  local cur updated
  cur="$(kv_get "$p" | jq -c '.data.data // {}')"
  updated="$(jq -c '
      del(.["spring.cloud.config.server.composite[0].host"])
    | del(.["spring.cloud.config.server.composite[0].scheme"])
    | del(.["spring.cloud.config.server.composite[0].port"])
  ' <<<"$cur")"
  kv_put "$p" "$updated"
}

echo "[SCAN] Searching for composite[0] host/scheme/port"
for p in "${PATHS[@]}"; do
  echo -e "\n-- $p --"
  show_keys "$p"
done

echo -e "\n[ACTION] Patching all candidate paths to vault:8200 (http)"
for p in "${PATHS[@]}"; do
  patch_to_vault "$p"
done

echo -e "\n[VERIFY] After patch:"
for p in "${PATHS[@]}"; do
  echo -e "\n-- $p --"
  show_keys "$p"
done

echo -e "\n[RESTART] Restarting config-server..."
docker compose restart config-server

echo -e "\n[CHECK] Config-server sees:"
curl -s http://config-server:8088/actuator/env | jq '
  [ .propertySources[]?
  | select(.name|test("VaultPropertySource"))
  | {name,
     host:(.properties["spring.cloud.config.server.composite[0].host"]?.value),
     scheme:(.properties["spring.cloud.config.server.composite[0].scheme"]?.value),
     port:(.properties["spring.cloud.config.server.composite[0].port"]?.value)} ]'
