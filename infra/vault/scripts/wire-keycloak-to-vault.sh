#!/usr/bin/env bash
# Wire Keycloak bootstrap output into Vault (KV v2).
# - Can run the Keycloak bootstrap script OR read a saved output file.
# - Pushes issuer/jwks + per-client client-credentials to the expected Vault paths.
set -euo pipefail

# --- Config ---
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:18300}"
TOKEN="${TOKEN:-}"                       # REQUIRED: root/admin token (or any token with write perms)
ENV_NAME="${ENV_NAME:-dev}"              # dev|staging|prod (affects the per-service paths)
MOUNT="${MOUNT:-secret}"                 # KV v2 mount
BOOTSTRAP_CMD="${BOOTSTRAP_CMD:-}"       # If set, command to run your Keycloak bootstrap (bash script)
OUTPUT_FILE="${OUTPUT_FILE:-}"           # If set, read this file instead of running BOOTSTRAP_CMD
ENABLE_JWT="${ENABLE_JWT:-true}"         # Write security.jwt.enabled=true to application/composite
DRY_RUN="${DRY_RUN:-false}"

[ -z "$TOKEN" ] && { echo "ERROR: set TOKEN env var"; exit 2; }

auth_hdr=(-H "X-Vault-Token: $TOKEN")
echo "==> VAULT_ADDR=$VAULT_ADDR  ENV=$ENV_NAME  MOUNT=$MOUNT  DRY_RUN=$DRY_RUN"

# --- helpers ---
kv2_write_json() {
  local rel="$1" json="$2"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRYRUN] POST $VAULT_ADDR/v1/$MOUNT/data/$rel  $json"
  else
    curl -fsS "${auth_hdr[@]}" -H 'Content-Type: application/json' \
      -X POST "$VAULT_ADDR/v1/$MOUNT/data/$rel" -d "{\"data\":$json}" >/dev/null
  fi
  echo "WROTE: $MOUNT/data/$rel"
}

# --- get bootstrap output ---
buf="$(mktemp)"
cleanup(){ rm -f "$buf"; }
trap cleanup EXIT

if [ -n "${OUTPUT_FILE}" ]; then
  echo "Reading Keycloak outputs from: $OUTPUT_FILE"
  cat "$OUTPUT_FILE" > "$buf"
elif [ -n "${BOOTSTRAP_CMD}" ]; then
  echo "Running bootstrap: $BOOTSTRAP_CMD"
  bash -lc "$BOOTSTRAP_CMD" | tee "$buf"
else
  echo "Paste the FULL output from your Keycloak bootstrap, then Ctrl-D:"
  cat > "$buf"
fi

# --- parse issuer / jwks ---
ISSUER="$(awk -F': ' '/^== Realm ==/{f=1;next} f&&/^Issuer URI/{print $2; exit}' "$buf" | tr -d '\r')"
JWKS="$(awk   -F': ' '/^== Realm ==/{f=1;next} f&&/^JWKS URI/{print $2; exit}'   "$buf" | tr -d '\r')"

if [ -z "$ISSUER" ] || [ -z "$JWKS" ]; then
  echo "ERROR: could not parse Issuer/JWKS from bootstrap output." >&2
  echo "       Ensure your bootstrap prints the '== Realm ==' block." >&2
  exit 1
fi
echo "Parsed Issuer=$ISSUER"
echo "Parsed JWKS=$JWKS"

# --- parse per-client creds ---
# expects lines like:
#   CONFIG_SERVER_CLIENT_ID=config-server
#   CONFIG_SERVER_CLIENT_SECRET=xxxxx
#   EUREKA_SERVER_CLIENT_ID=eureka-server
#   EUREKA_SERVER_CLIENT_SECRET=yyyyy
#   DANIPA_FINTECH_SERVICE_CLIENT_ID=danipa-fintech-service
#   DANIPA_FINTECH_SERVICE_CLIENT_SECRET=zzzzz

get_kv() { awk -F'=' -v k="$1" '$1==k{print $2}' "$buf" | tr -d '\r'; }

CFG_ID="$(   get_kv 'CONFIG_SERVER_CLIENT_ID'           || true)"
CFG_SEC="$(  get_kv 'CONFIG_SERVER_CLIENT_SECRET'       || true)"
EUREKA_ID="$(get_kv 'EUREKA_SERVER_CLIENT_ID'           || true)"
EUREKA_SEC="$(get_kv 'EUREKA_SERVER_CLIENT_SECRET'      || true)"
FIN_ID="$(   get_kv 'DANIPA_FINTECH_SERVICE_CLIENT_ID'  || true)"
FIN_SEC="$(  get_kv 'DANIPA_FINTECH_SERVICE_CLIENT_SECRET' || true)"

# Token endpoint from issuer
TOKEN_URI="${ISSUER%/}/protocol/openid-connect/token"

# --- write application/composite (issuer, jwks, enable JWT) ---
jwt_enabled="$ENABLE_JWT"
app_json="$(python3 - <<PY
import json,sys
print(json.dumps({
  "SECURITY_JWT_ENABLED": "$jwt_enabled",
  "SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI": "$ISSUER",
  "SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI": "$JWKS"
}, separators=(",",":")))
PY
)"
kv2_write_json "application/composite" "$app_json"

# --- write fintech service creds ---
if [ -n "$FIN_ID" ] && [ -n "$FIN_SEC" ]; then
  fin_json="$(python3 - <<PY
import json,sys
print(json.dumps({
  "SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_CLIENT_ID": "$FIN_ID",
  "SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_CLIENT_SECRET": "$FIN_SEC",
  "SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_ACCESS_TOKEN_URI": "$TOKEN_URI"
}, separators=(",",":")))
PY
)"
  kv2_write_json "danipa-fintech-service,${ENV_NAME}" "$fin_json"
else
  echo "WARN: fintech client credentials not found in output; skipping."
fi

# --- write eureka server creds ---
if [ -n "$EUREKA_ID" ] && [ -n "$EUREKA_SEC" ]; then
  eureka_json="$(python3 - <<PY
import json,sys
print(json.dumps({
  "SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_CLIENT_ID": "$EUREKA_ID",
  "SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_CLIENT_SECRET": "$EUREKA_SEC",
  "SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_ACCESS_TOKEN_URI": "$TOKEN_URI"
}, separators=(",",":")))
PY
)"
  kv2_write_json "danipa-eureka-server,${ENV_NAME}" "$eureka_json"
else
  echo "WARN: eureka client credentials not found in output; skipping."
fi

echo "All done. Vault now has issuer/jwks + client credentials for ENV=$ENV_NAME."
echo "Next steps:"
echo "  1) (If you temporarily disabled JWT) set security.jwt.enabled back to true (done above if ENABLE_JWT=true)."
echo "  2) restart config-server, then start fintech & eureka."
