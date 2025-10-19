#!/usr/bin/env sh
# --------------------------------------------------------------------
# Postgres container health check
#  - Validates secret env file & required vars
#  - Verifies file readability & format (no CRLF)
#  - Validates Vault reachability (TCP + TLS + /sys/health)
#  - Confirms Postgres readiness via pg_isready
# --------------------------------------------------------------------
set -eu

ENV_FILE="/opt/pg-secrets/db-bootstrap.env"

# Vault connection settings
VAULT_CONNECT="${VAULT_CONNECT:-vault:8200}"                       # docker service:port
VAULT_HOSTNAME="${VAULT_TLS_SERVER_NAME:-vault.local.danipa.com}"  # SNI hostname
VAULT_CACERT="${VAULT_CACERT:-/vault/tls/root_ca.crt}"
VAULT_ADDR="${VAULT_ADDR:-https://${VAULT_HOSTNAME}:8200}"

REQUIRED_VARS="ENVIRONMENT DB_NAME DB_SCHEMA APP_ROLE RO_ROLE APP_ROLE_PASSWORD RO_ROLE_PASSWORD"

# --------------------------------------------------------------------
echo "🔍 Checking Postgres secret environment..."

# Ensure file exists, nonempty, readable
if [ ! -r "$ENV_FILE" ]; then
  echo "❌ Env file missing or unreadable: $ENV_FILE"
  exit 1
fi
if [ ! -s "$ENV_FILE" ]; then
  echo "❌ Env file is empty: $ENV_FILE"
  exit 1
fi

# Detect Windows CRLFs
if grep -q $'\r' "$ENV_FILE"; then
  echo "❌ Env file contains CRLF line endings — fix with 'dos2unix $ENV_FILE'"
  exit 6
fi

# Load vars
set -a; . "$ENV_FILE"; set +a

# Validate required vars
missing=0
for var in $REQUIRED_VARS; do
  eval "val=\${$var:-}"
  if [ -z "$val" ]; then
    echo "⚠️  Missing variable: $var"
    missing=$((missing + 1))
  fi
done
if [ "$missing" -gt 0 ]; then
  echo "❌ $missing variable(s) missing or empty in env"
  exit 2
fi
echo "✅ All secret variables loaded from $ENV_FILE"

# --------------------------------------------------------------------
# Vault connectivity (TCP + TLS)
# --------------------------------------------------------------------
echo "🔍 Checking Vault connectivity..."

if command -v openssl >/dev/null 2>&1; then
  if timeout 5 openssl s_client -connect "$VAULT_CONNECT" -servername "$VAULT_HOSTNAME" \
       -CAfile "$VAULT_CACERT" </dev/null > /tmp/vault_tls.txt 2>&1; then
    if grep -q "Verify return code: 0 (ok)" /tmp/vault_tls.txt; then
      echo "✅ Vault TLS validated (SNI $VAULT_HOSTNAME via $VAULT_CONNECT, CA OK)"
    else
      echo "⚠️  TLS handshake completed but certificate verification not clean"
    fi
  else
    echo "❌ Could not complete TLS handshake to $VAULT_CONNECT"
    exit 4
  fi
else
  echo "ℹ️  openssl not available; skipping TLS check"
fi

# --------------------------------------------------------------------
# HTTP /v1/sys/health via openssl
# --------------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
  req="GET /v1/sys/health HTTP/1.1\r\nHost: ${VAULT_HOSTNAME}\r\nConnection: close\r\n\r\n"
  if printf "%b" "$req" | timeout 5 \
     openssl s_client -quiet -connect "$VAULT_CONNECT" \
       -servername "$VAULT_HOSTNAME" -CAfile "$VAULT_CACERT" >/tmp/vault_http.txt 2>/dev/null; then

    status="$(head -n1 /tmp/vault_http.txt | awk '{print $2}')"
    case "$status" in
      200|429|472|473)
        echo "✅ Vault /sys/health HTTP ${status} (acceptable)"
        ;;
      501|503)
        echo "❌ Vault /sys/health HTTP ${status} (not initialized or sealed)"
        exit 5
        ;;
      *)
        echo "⚠️  Vault /sys/health returned HTTP ${status:-unknown}"
        ;;
    esac
  else
    echo "⚠️  Could not perform HTTPS health request via openssl"
  fi
else
  echo "ℹ️  openssl not present; skipping HTTP health check"
fi

# --------------------------------------------------------------------
# Postgres readiness
# --------------------------------------------------------------------
echo "🔍 Verifying local DB readiness..."
if pg_isready -U "${POSTGRES_USER:-$APP_ROLE}" -d "${POSTGRES_DB:-$DB_NAME}" -h localhost >/dev/null 2>&1; then
  echo "✅ Postgres is accepting connections"
else
  echo "❌ Postgres is not responding locally"
  exit 3
fi

echo "🏁 All checks passed"
