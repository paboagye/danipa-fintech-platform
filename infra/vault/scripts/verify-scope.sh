#!/usr/bin/env bash
set -euo pipefail

# Usage: ./infra/vault/scripts/verify-scope.sh <client-id> <client-secret> [scope]
# Example: ./infra/vault/scripts/verify-scope.sh eureka-server q8nd... config.read

ADMIN_URL="${ADMIN_URL:-http://localhost:8082}"
REALM="${REALM:-danipa}"

CID="${1:-}"
SEC="${2:-}"
REQ_SCOPE="${3:-}"

if [[ -z "$CID" || -z "$SEC" ]]; then
  echo "Usage: $0 <client-id> <client-secret> [scope]"
  exit 1
fi

echo "== Minting token for $CID (scope=${REQ_SCOPE:-none}) =="

RAW=$(curl -s -X POST "$ADMIN_URL/realms/$REALM/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d grant_type=client_credentials \
  -d client_id="$CID" \
  -d client_secret="$SEC" \
  ${REQ_SCOPE:+-d scope="$REQ_SCOPE"})

if [[ "$(jq -r '.error // empty' <<<"$RAW")" != "" ]]; then
  echo "❌ Error: $(jq -r '.error_description' <<<"$RAW")"
  exit 2
fi

TOKEN=$(jq -r '.access_token' <<<"$RAW")

echo "--- decoded token ---"
cut -d. -f2 <<<"$TOKEN" | tr '_-' '/+' | base64 -d 2>/dev/null \
  | jq '{azp, aud, scope, roles: .realm_access.roles}'
