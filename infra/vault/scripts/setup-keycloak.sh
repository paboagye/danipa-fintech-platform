#!/usr/bin/env bash
# Keycloak realm bootstrap (bash)
# - Creates/updates realm
# - Ensures realm role "config.read"
# - Ensures confidential clients with service accounts, grants role
# - Prints issuer/JWKS and client secrets
#
# Deps: curl, jq
# Usage:
#   KC_BASE=http://localhost:8082 \
#   KC_ADMIN_USER=admin KC_ADMIN_PASS=admin \
#   KC_REALM=danipa \
#   ./setup-keycloak.sh
#
# Rotate a client’s secret (all ensured clients):
#   ROTATE_SECRET=1 ./setup-keycloak.sh
#
# Customize clients (CSV of id=Display Name):
#   CLIENTS="config-server=Config Server (server-to-server),eureka-server=Eureka Server (server-to-server),danipa-fintech-service=Fintech Service (server-to-server)" ./setup-keycloak.sh

set -euo pipefail

# ---------- Config (env overrides) ----------
KC_BASE="${KC_BASE:-http://localhost:8082}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
KC_REALM="${KC_REALM:-danipa}"
ROTATE_SECRET="${ROTATE_SECRET:-0}"   # 1 to rotate, else 0
ROLE_NAME="config.read"

# Default clients list if CLIENTS not provided
CLIENTS="${CLIENTS:-config-server=Config Server (server-to-server),eureka-server=Eureka Server (server-to-server),danipa-fintech-service=Fintech Service (server-to-server)}"

# ---------- Helpers ----------
require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found." >&2; exit 1; }; }
require curl
require jq

log() { printf '%s\n' "$*" >&2; }

# Acquire admin token from master realm
get_admin_token() {
  local resp
  resp="$(curl -sS -X POST \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "client_id=admin-cli&username=${KC_ADMIN_USER}&password=${KC_ADMIN_PASS}&grant_type=password" \
    "${KC_BASE}/realms/master/protocol/openid-connect/token")"
  echo "$resp" | jq -r '.access_token // empty'
}

# Generic request with bearer
kc() {
  # kc METHOD URL [JSON_BODY]
  local method="$1"; shift
  local url="$1"; shift
  local body="${1:-}"

  if [ -n "$body" ]; then
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H 'Content-Type: application/json; charset=utf-8' \
      --data-binary "$body"
  else
    curl -sS -X "$method" "$url" \
      -H "Authorization: Bearer $ADMIN_TOKEN"
  fi
}

try_get() {
  # try_get URL -> prints body or empty
  curl -sS -X GET "$1" -H "Authorization: Bearer $ADMIN_TOKEN" || true
}

ensure_realm() {
  # Create if missing; otherwise patch core lifetimes & policy
  local got
  got="$(try_get "${KC_BASE}/admin/realms/${KC_REALM}")"
  if [ -z "$got" ] || [ "$(echo "$got" | jq -r '.realm // empty')" != "$KC_REALM" ]; then
    log "Creating realm '${KC_REALM}'…"
    kc POST "${KC_BASE}/admin/realms" "$(jq -n --arg r "$KC_REALM" '
      {
        realm: $r, enabled: true,
        loginWithEmailAllowed: true,
        verifyEmail: false,
        sslRequired: "external",
        accessTokenLifespan: 300,
        ssoSessionIdleTimeout: 1800,
        ssoSessionMaxLifespan: 28800,
        offlineSessionIdleTimeout: 2592000,
        passwordPolicy: "length(12) and lowerCase(1) and upperCase(1) and digits(1) and specialChars(1) and notUsername() and passwordHistory(5)"
      }') " >/dev/null
  else
    log "Realm '${KC_REALM}' exists. Updating lifetimes/policy…"
    kc PUT "${KC_BASE}/admin/realms/${KC_REALM}" '{
      "accessTokenLifespan": 300,
      "ssoSessionIdleTimeout": 1800,
      "ssoSessionMaxLifespan": 28800,
      "offlineSessionIdleTimeout": 2592000,
      "passwordPolicy": "length(12) and lowerCase(1) and upperCase(1) and digits(1) and specialChars(1) and notUsername() and passwordHistory(5)"
    }' >/dev/null
  fi
}

ensure_realm_role() {
  local role
  role="$(try_get "${KC_BASE}/admin/realms/${KC_REALM}/roles/${ROLE_NAME}")"
  if [ -z "$role" ] || [ "$(echo "$role" | jq -r '.name // empty')" != "$ROLE_NAME" ]; then
    log "Creating realm role '${ROLE_NAME}'…"
    kc POST "${KC_BASE}/admin/realms/${KC_REALM}/roles" \
      "$(jq -n --arg n "$ROLE_NAME" --arg d 'Read access to config endpoints' '{name:$n, description:$d}')" >/dev/null
    role="$(kc GET "${KC_BASE}/admin/realms/${KC_REALM}/roles/${ROLE_NAME}")"
  else
    log "Realm role '${ROLE_NAME}' already exists."
  fi
  # print role JSON to stdout for caller
  echo "$role"
}

# Ensure confidential client with service account; grant realm role to svc user; manage secret
ensure_confidential_client() {
  local client_id="$1" display_name="$2" role_json="$3"
  local found client client_uuid svc_user assigned has_role=0 secret_value

  found="$(kc GET "${KC_BASE}/admin/realms/${KC_REALM}/clients?clientId=$(printf '%s' "$client_id" | jq -sRr @uri)")"
  if [ "$(echo "$found" | jq 'length')" -eq 0 ]; then
    log "Creating client '${client_id}'…"
    kc POST "${KC_BASE}/admin/realms/${KC_REALM}/clients" \
      "$(jq -n --arg id "$client_id" --arg name "$display_name" '{
          clientId: $id, name: $name, enabled: true,
          protocol: "openid-connect", publicClient: false,
          serviceAccountsEnabled: true,
          directAccessGrantsEnabled: false,
          standardFlowEnabled: false,
          implicitFlowEnabled: false,
          authorizationServicesEnabled: false,
          bearerOnly: false,
          attributes: {"access.token.lifespan": "300"},
          redirectUris: ["*"], webOrigins: ["*"]
        }')" >/dev/null
    found="$(kc GET "${KC_BASE}/admin/realms/${KC_REALM}/clients?clientId=$(printf '%s' "$client_id" | jq -sRr @uri)")"
  else
    log "Client '${client_id}' already exists."
  fi

  client="$(echo "$found" | jq -r '.[0]')"
  client_uuid="$(echo "$client" | jq -r '.id')"

  # Service account user
  svc_user="$(kc GET "${KC_BASE}/admin/realms/${KC_REALM}/clients/${client_uuid}/service-account-user")"
  # Check role mapping
  assigned="$(kc GET "${KC_BASE}/admin/realms/${KC_REALM}/users/$(echo "$svc_user" | jq -r '.id')/role-mappings/realm")"
  if echo "$assigned" | jq -e --arg rn "$ROLE_NAME" 'map(select(.name==$rn)) | length>0' >/dev/null; then
    has_role=1
  fi
  if [ "$has_role" -eq 0 ]; then
    log "Granting '${ROLE_NAME}' to service account for '${client_id}'…"
    kc POST "${KC_BASE}/admin/realms/${KC_REALM}/users/$(echo "$svc_user" | jq -r '.id')/role-mappings/realm" \
      "$(jq -n --arg id "$(echo "$role_json" | jq -r '.id')" --arg name "$ROLE_NAME" '[{id:$id,name:$name}]')" >/dev/null
  fi

  # Secret: rotate or get
  if [ "$ROTATE_SECRET" = "1" ]; then
    log "Rotating secret for '${client_id}'…"
    secret_value="$(kc POST "${KC_BASE}/admin/realms/${KC_REALM}/clients/${client_uuid}/client-secret" '{}' | jq -r '.value')"
  else
    secret_value="$(try_get "${KC_BASE}/admin/realms/${KC_REALM}/clients/${client_uuid}/client-secret" | jq -r '.value // empty')"
    if [ -z "$secret_value" ] || [ "$secret_value" = "null" ]; then
      secret_value="$(kc POST "${KC_BASE}/admin/realms/${KC_REALM}/clients/${client_uuid}/client-secret" '{}' | jq -r '.value')"
    fi
  fi

  jq -n --arg id "$client_id" --arg secret "$secret_value" '{clientId:$id, secret:$secret}'
}

# ---------- Main ----------
log "== Keycloak =="
log "Base   : $KC_BASE"
log "Realm  : $KC_REALM"
log "Rotate : $ROTATE_SECRET"
log ""

ADMIN_TOKEN="$(get_admin_token)"
[ -n "$ADMIN_TOKEN" ] || { echo "ERROR: could not get admin token (is Keycloak up and admin creds correct?)" >&2; exit 1; }

ensure_realm
ROLE_JSON="$(ensure_realm_role)"

# Parse CLIENTS CSV into pairs
IFS=',' read -r -a _CLIENT_PAIRS <<<"$CLIENTS"
RESULTS="[]"
for pair in "${_CLIENT_PAIRS[@]}"; do
  # split on first '=' only
  cid="${pair%%=*}"
  name="${pair#*=}"
  cid="$(echo -n "$cid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  name="$(echo -n "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$cid" ] || continue
  res="$(ensure_confidential_client "$cid" "$name" "$ROLE_JSON")"
  RESULTS="$(jq -cn --argjson A "$RESULTS" --argjson B "$res" '$A + [$B]')"
done

ISSUER="${KC_BASE}/realms/${KC_REALM}"
JWKS="${ISSUER}/protocol/openid-connect/certs"

echo ""
echo "== Realm =="
echo "Issuer URI : ${ISSUER}"
echo "JWKS URI   : ${JWKS}"
echo ""

echo "== Client Credentials (store in Vault / env) =="
echo "$RESULTS" | jq -r '
  .[] | [
    (.clientId | gsub("-"; "_") | ascii_upcase) + "_CLIENT_ID=" + .clientId,
    (.clientId | gsub("-"; "_") | ascii_upcase) + "_CLIENT_SECRET=" + .secret
  ] | .[]'
echo ""
echo "Grant used: realm role '\''config.read'\'' (already ensured)."
