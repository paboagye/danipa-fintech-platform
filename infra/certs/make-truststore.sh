#!/usr/bin/env bash
set -euo pipefail

# Inputs (adjust paths if yours differ)
STEP_ROOT="./infra/step/root_ca.crt"
OUT_DIR="./infra/certs"
OUT_P12="$OUT_DIR/danipa-truststore.p12"

# Password: set via env TRUSTSTORE_PASSWORD or default
: "${TRUSTSTORE_PASSWORD:=changeit}"

mkdir -p "$OUT_DIR"

if [[ ! -s "$STEP_ROOT" ]]; then
  echo "✖ Step root CA not found at $STEP_ROOT"
  exit 1
fi

# Recreate idempotently
rm -f "$OUT_P12"

# keytool happily imports a PEM CA cert into a PKCS12 truststore.
keytool -importcert \
  -alias step-root \
  -file "$STEP_ROOT" \
  -keystore "$OUT_P12" \
  -storetype PKCS12 \
  -storepass "$TRUSTSTORE_PASSWORD" \
  -noprompt

echo "✔ Wrote truststore: $OUT_P12"
echo "   Store type: PKCS12"
echo "   Password : (set via TRUSTSTORE_PASSWORD; defaulted to 'changeit')"
