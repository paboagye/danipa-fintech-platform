CA=infra/vault/tls/root_ca.crt
TOK=$(cat /tmp/vault_composite_token_dev)
VAULT_ADDR=https://vault.local.danipa.com
MOUNT=secret
KEY=SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_CLIENT_SECRET

# Candidates to check (both comma & slash forms; env and base)
paths=(
  "danipa-fintech-service,dev"
  "danipa-fintech-service/dev"
  "danipa-fintech-service,composite"
  "danipa-fintech-service/composite"
  "danipa-fintech-service"                # base (no profile)
)

for p in "${paths[@]}"; do
  val=$(
    curl -sS --cacert "$CA" -H "X-Vault-Token: $TOK" \
      "$VAULT_ADDR/v1/$MOUNT/data/$p" \
    | jq -r --arg k "$KEY" '(.data.data[$k] // "∅")' 2>/dev/null
  )
  echo "$p -> $val"
done