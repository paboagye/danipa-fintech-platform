# Point to the actual PEM for your Step root (verify file exists!)
export VAULT_ADDR="https://vault:8200"
export VAULT_CACERT="infra/vault/tls/root_ca.crt"   # adjust if needed
test -f "$VAULT_CACERT" || { echo "No CA at $VAULT_CACERT"; return; }

# If you’re hitting Vault via 127.0.0.1 but need SNI for vault.local.danipa.com:
# curl ... --resolve vault.local.danipa.com:443:127.0.0.1

CFG_TOKEN=$(
  curl -sS --cacert "$VAULT_CACERT" \
    -H "X-Vault-Token: $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"policies":["read-config-server-secrets-dev"],"ttl":"24h","no_default_policy":true}' \
    "$VAULT_ADDR/v1/auth/token/create" | jq -r '.auth.client_token'
)
echo "Minted: ${CFG_TOKEN:0:8}…"

curl -sS --cacert "$VAULT_CACERT" \
  -H "X-Vault-Token: $TOKEN" \
  "$VAULT_ADDR/v1/secret/data/danipa-config-server,composite" \
| jq '.data.data' > /tmp/cfg.json

jq --arg tok "$CFG_TOKEN" \
  '. + {"spring.cloud.config.server.composite[0].token":$tok}' \
  /tmp/cfg.json > /tmp/cfg.new.json

curl -sS --cacert "$VAULT_CACERT" \
  -H "X-Vault-Token: $TOKEN" -H 'Content-Type: application/json' \
  -X POST "$VAULT_ADDR/v1/secret/data/danipa-config-server,composite" \
  -d "{\"data\":$(cat /tmp/cfg.new.json)}"
