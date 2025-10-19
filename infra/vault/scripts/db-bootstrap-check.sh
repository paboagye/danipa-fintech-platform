#!/usr/bin/env sh
set -eu

ENV_FILE="/opt/pg-secrets/db-bootstrap.env"
REQUIRED_VARS="ENVIRONMENT DB_NAME DB_SCHEMA APP_ROLE RO_ROLE APP_ROLE_PASSWORD RO_ROLE_PASSWORD"

if [ ! -s "$ENV_FILE" ]; then
  echo "❌ Missing or empty env file: $ENV_FILE"
  exit 1
fi

# shellcheck disable=SC1090
set -a
. "$ENV_FILE"
set +a

missing=0
for var in $REQUIRED_VARS; do
  eval "val=\${$var:-}"
  if [ -z "$val" ]; then
    echo "⚠️  Missing: $var"
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo "❌ $missing variable(s) missing or empty"
  exit 2
fi

echo "✅ All required variables present"
