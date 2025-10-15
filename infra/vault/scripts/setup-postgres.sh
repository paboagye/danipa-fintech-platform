#!/usr/bin/env bash
set -euo pipefail

# --- Settings ---
VAULT_ADDR="https://127.0.0.1:8200"
VAULT_CACERT="$(pwd)/infra/vault/tls/root_ca.crt"
ROLE="fintech-role-dev"
DB_USER="danipa_owner_dev"
DB_PASS="changeMeDevDBA!"
DB_NAME="danipa_fintech_db_dev"
DB_CONT="danipa-postgres-dev"

# --- 1. Ensure pg-read policy exists ---
cat >/tmp/pg-read.hcl <<HCL
path "secret/data/danipa/fintech/dev" {
  capabilities = ["read"]
}
path "secret/metadata/danipa/fintech/*" {
  capabilities = ["list"]
}
HCL
vault policy write pg-read /tmp/pg-read.hcl

# --- 2. Attach pg-read to the AppRole ---
CUR=$(vault read -field=policies auth/approle/role/$ROLE 2>/dev/null || echo "")
NEW=$(printf "%s,pg-read\n" "$CUR" | tr -d '[]," ' | tr ',' '\n' | sort -u | paste -sd, -)
vault write auth/approle/role/$ROLE policies="$NEW"

# --- 3. Reset DB password to match Vault secret ---
docker exec -i $DB_CONT psql -U $DB_USER -d postgres -c \
  "ALTER ROLE $DB_USER WITH PASSWORD '$DB_PASS';"

# --- 4. Verify connection works inside container ---
docker exec -e PGPASSWORD="$DB_PASS" -i $DB_CONT \
  psql -h 127.0.0.1 -U $DB_USER -d $DB_NAME \
  -c "select current_user, now();"
