#!/usr/bin/env bash
set -euo pipefail

# One-shot initializer for a specific environment: dev|staging|prod
# Example:
#   export VAULT_ADDR=http://127.0.0.1:8200
#   export VAULT_TOKEN=<root-or-admin-token>
#   Run below in bash
#   ENV_FILE=../../danipa-fintech-platform/.env.dev ./scripts/vault-init-env.sh dev

env_name="${1:-}"
if [[ -z "$env_name" ]]; then
  echo "Usage: $0 <dev|staging|prod>" >&2
  exit 1
fi

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="$root/out"
mkdir -p "$out"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing binary: $1" >&2; exit 1; }; }
need vault
need jq

: "${VAULT_ADDR:?Set VAULT_ADDR (e.g., http://127.0.0.1:8200)}"
: "${VAULT_TOKEN:?Set VAULT_TOKEN (login first if not dev mode)}"

# Load variables from an env file if provided
if [[ -n "${ENV_FILE:-}" ]]; then
  if [[ -f "$ENV_FILE" ]]; then
    echo "==> Loading variables from ENV_FILE: $ENV_FILE"
    # shellcheck disable=SC1090
    set -a
    source "$ENV_FILE"
    set +a
  else
    echo "!! ENV_FILE was set but file not found: $ENV_FILE" >&2
    exit 1
  fi
fi

echo "==> Enable KV v2 at 'secret' (idempotent)"
vault secrets enable -path=secret -version=2 kv || true

echo "==> Write policies"
vault policy write "fintech-${env_name}" "$root/policies/fintech-${env_name}.hcl"
vault policy write config-server "$root/policies/config-server.hcl"

echo "==> Enable AppRole (idempotent)"
vault auth enable approle || true

echo "==> Create AppRoles"
vault write "auth/approle/role/fintech-${env_name}"   token_policies="fintech-${env_name}"   secret_id_ttl=24h token_ttl=1h token_max_ttl=24h   bind_secret_id=true

# Config server uses same policy across envs (or split later if desired)
vault write auth/approle/role/config-server   token_policies="config-server"   secret_id_ttl=24h token_ttl=1h token_max_ttl=24h   bind_secret_id=true

echo "==> Save role_id and generate secret_id (under ./out)"
vault read -format=json "auth/approle/role/fintech-${env_name}/role-id" | jq -r .data.role_id > "$out/fintech-${env_name}.role_id"
vault write -f -format=json "auth/approle/role/fintech-${env_name}/secret-id" | jq -r .data.secret_id > "$out/fintech-${env_name}.secret_id"

vault read -format=json auth/approle/role/config-server/role-id | jq -r .data.role_id > "$out/config-server.role_id"
vault write -f -format=json auth/approle/role/config-server/secret-id | jq -r .data.secret_id > "$out/config-server.secret_id"

echo "==> Seed secrets for ${env_name} (if variables are present)"
# Config Server basic auth (shared unless you prefer per-env)
if [[ -n "${CONFIG_USER:-}" || -n "${CONFIG_PASS:-}" ]]; then
  vault kv put secret/danipa/config     config.user="${CONFIG_USER:-cfg-user}"     config.pass="${CONFIG_PASS:-cfg-pass}" >/dev/null
  echo "   - secret/danipa/config"
fi

# Fintech per-env values (Actuator + MoMo)
if [[ -n "${MOMO_API_USER_ID:-}" || -n "${ACTUATOR_USER:-}" ]]; then
  vault kv put "secret/danipa/fintech/${env_name}"     actuator.user="${ACTUATOR_USER:-act}"     actuator.pass="${ACTUATOR_PASS:-act-pass}"     momo.apiUserId="${MOMO_API_USER_ID:-CHANGE_ME}"     momo.apiKey="${MOMO_API_KEY:-CHANGE_ME}"     momo.remittance.subscriptionKey="${MOMO_REMITTANCE_SUBSCRIPTION_KEY:-CHANGE_ME}"     momo.collection.subscriptionKey="${MOMO_COLLECTION_SUBSCRIPTION_KEY:-CHANGE_ME}"     momo.disbursements.subscriptionKey="${MOMO_DISBURSEMENTS_SUBSCRIPTION_KEY:-CHANGE_ME}"     momo.callbackUrl="${MOMO_CALLBACK_URL:-https://example-callback}" >/dev/null
  echo "   - secret/danipa/fintech/${env_name}"
fi

# Postgres per-env values
if [[ -n "${POSTGRES_USER_DEV:-${POSTGRES_ADMIN_USER:-}}" || -n "${POSTGRES_APP_USER_DEV:-${POSTGRES_APP_USER:-}}" ]]; then
  # Map conventional dev/staging/prod variable names if present
  case "$env_name" in
    dev)
      pg_admin_user="${POSTGRES_USER_DEV:-${POSTGRES_ADMIN_USER:-}}"
      pg_admin_pass="${POSTGRES_PASSWORD_DEV:-${POSTGRES_ADMIN_PASSWORD:-}}"
      pg_db="${POSTGRES_DB_DEV:-${POSTGRES_DB:-}}"
      pg_app_user="${POSTGRES_APP_USER_DEV:-${POSTGRES_APP_USER:-}}"
      pg_app_pass="${POSTGRES_APP_PASS_DEV:-${POSTGRES_APP_PASSWORD:-}}"
      pg_port="${PG_PORT_DEV:-${POSTGRES_PORT:-5432}}"
      ;;
    staging)
      pg_admin_user="${POSTGRES_USER_STAGING:-${POSTGRES_ADMIN_USER:-}}"
      pg_admin_pass="${POSTGRES_PASSWORD_STAGING:-${POSTGRES_ADMIN_PASSWORD:-}}"
      pg_db="${POSTGRES_DB_STAGING:-${POSTGRES_DB:-}}"
      pg_app_user="${POSTGRES_APP_USER_STAGING:-${POSTGRES_APP_USER:-}}"
      pg_app_pass="${POSTGRES_APP_PASS_STAGING:-${POSTGRES_APP_PASSWORD:-}}"
      pg_port="${PG_PORT_STAGING:-${POSTGRES_PORT:-5432}}"
      ;;
    prod)
      pg_admin_user="${POSTGRES_USER_PROD:-${POSTGRES_ADMIN_USER:-}}"
      pg_admin_pass="${POSTGRES_PASSWORD_PROD:-${POSTGRES_ADMIN_PASSWORD:-}}"
      pg_db="${POSTGRES_DB_PROD:-${POSTGRES_DB:-}}"
      pg_app_user="${POSTGRES_APP_USER_PROD:-${POSTGRES_APP_USER:-}}"
      pg_app_pass="${POSTGRES_APP_PASS_PROD:-${POSTGRES_APP_PASSWORD:-}}"
      pg_port="${PG_PORT_PROD:-${POSTGRES_PORT:-5432}}"
      ;;
  esac

  if [[ -n "${pg_admin_user:-}" || -n "${pg_app_user:-}" ]]; then
    vault kv put "secret/danipa/postgres/${env_name}"       postgres.admin.user="${pg_admin_user:-CHANGE_ME}"       postgres.admin.password="${pg_admin_pass:-CHANGE_ME}"       postgres.db="${pg_db:-CHANGE_ME}"       postgres.app.user="${pg_app_user:-CHANGE_ME}"       postgres.app.password="${pg_app_pass:-CHANGE_ME}"       postgres.port="${pg_port:-5432}" >/dev/null
    echo "   - secret/danipa/postgres/${env_name}"
  fi
fi

echo "==> Completed for ${env_name}. AppRole credentials in $out/"
