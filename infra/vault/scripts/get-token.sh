TOKEN="$(jq -r .root_token infra/vault/keys/vault-keys.json)" \
  ./infra/vault/scripts/write-secrets.sh VERIFY_ONLY=true SHOW_VALUES=false
