#!/usr/bin/env bash
set -euo pipefail

# Generate .env.vault.<env> from ./out/ after running vault-init-env.sh
env_arg="${1:-}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/out"

make_one() {
  local env="$1"
  local dest="$root/.env.vault.${env}"
  local vault_uri="${VAULT_URI:-http://vault:8200}"

  local fintech_role_id="$(cat "$out/fintech-${env}.role_id")"
  local fintech_secret_id="$(cat "$out/fintech-${env}.secret_id")"
  local cfg_role_id="$(cat "$out/config-server.role_id")"
  local cfg_secret_id="$(cat "$out/config-server.secret_id")"

  cat > "$dest" <<EOF
# Generated from ./out by make-envfiles.sh
VAULT_URI=${vault_uri}
FINTECH_VAULT_ROLE_ID=${fintech_role_id}
FINTECH_VAULT_SECRET_ID=${fintech_secret_id}
CONFIG_SERVER_VAULT_ROLE_ID=${cfg_role_id}
CONFIG_SERVER_VAULT_SECRET_ID=${cfg_secret_id}
EOF
  echo "Wrote $dest"
}

case "$env_arg" in
  dev|staging|prod) make_one "$env_arg" ;;
  all|"") for e in dev staging prod; do make_one "$e"; done ;;
esac
