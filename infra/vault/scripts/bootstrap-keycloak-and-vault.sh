#!/usr/bin/env bash
# One-shot bootstrap: Keycloak realm/clients + Vault seeding + policy/AppRole + gated health check
# Run from repo root: ./infra/vault/scripts/bootstrap-keycloak-and-vault.sh [--dry-run]
set -euo pipefail

# -------------------------------
# Flags / defaults
# -------------------------------
DRY_RUN=false
for arg in "${@:-}"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) echo "Usage: $0 [--dry-run]"; exit 0 ;;
    "") ;;
    *) echo "Unknown arg: $arg"; exit 2 ;;
  esac
done

# ---------- Endpoints / creds ----------
BASE_URL="${BASE_URL:-https://keycloak.local.danipa.com}"     # exposed by Traefik (public)
ADMIN_URL="${ADMIN_URL:-http://localhost:8082}"               # direct KC for admin API (bypass proxy)
REALM="${REALM:-danipa}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"

VAULT_ADDR="${VAULT_ADDR:-https://vault.local.danipa.com}"
MOUNT="${MOUNT:-secret}"
ENV_NAME="${ENV_NAME:-dev}"
SEEDS_DIR="${SEEDS_DIR:-infra/vault/seeds}"
SEEDS_FILE="${SEEDS_FILE:-$SEEDS_DIR/${ENV_NAME}.json}"
WRITE_SECRETS="${WRITE_SECRETS:-./infra/vault/scripts/write-secrets.sh}"

# ---------- TLS (shared) ----------
VAULT_CACERT="${VAULT_CACERT:-$(pwd)/infra/vault/tls/root_ca.crt}"
# Optional: pin hostnames to loopback while keeping TLS/SNI validation
# export CURL_FORCE_RESOLVE="keycloak.local.danipa.com:443:127.0.0.1;vault.local.danipa.com:443:127.0.0.1"
CURL_FORCE_RESOLVE="${CURL_FORCE_RESOLVE:-}"

# ---------- OAuth / misc ----------
TOKEN="${TOKEN:-}"  # If empty, read infra/vault/keys/vault-keys.json root_token
SCOPE_NAME="${SCOPE_NAME:-config.read}"
RESOURCE_CLIENT_ID="${RESOURCE_CLIENT_ID:-danipa-config-server}"  # audience your API expects
CALLER_CLIENTS_STR="${CALLER_CLIENTS_STR:-danipa-fintech-service eureka-server}"

# Best practice: OPTIONAL on callers, NOT realm default
SCOPE_AS_DEFAULT="${SCOPE_AS_DEFAULT:-false}"     # false => attach as OPTIONAL
REALM_DEFAULT_SCOPE="${REALM_DEFAULT_SCOPE:-false}"
HEALTH_URL="${HEALTH_URL:-http://localhost:8088/actuator/health}"

# Attach behavior: if OPTIONAL fails verification, optionally fall back to DEFAULT
FORCE_SCOPE_DEFAULT_ON_MISS="${FORCE_SCOPE_DEFAULT_ON_MISS:-false}"

# -------------------------------
# Tool checks
# -------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1"; exit 2; }; }
need curl; need jq; need sed; need python3; need mktemp

# -------------------------------
# Helpers
# -------------------------------
mask_val() {
  local s="$1"
  [[ -z "$s" || "$s" == "null" ]] && { printf "%s" "$s"; return; }
  if [[ "$s" =~ ^https?:// ]]; then
    local head tail
    head=$(printf "%s" "$s" | sed -E 's#^(https?://[^/]{1,2}).*#\1#')
    tail=$(printf "%s" "$s" | sed -E 's#.*(..)$#\1#')
    printf "%s%s" "${head:-$(printf "%.2s" "$s")}" "$(printf "%*s" $(( ${#s}-(${#head}+${#tail}) )) | tr ' ' '*')$tail"
  else
    local n=${#s}
    if (( n <= 4 )); then
      printf "%s" "$(printf "%*s" "$n" | tr ' ' '*')"
    else
      local pfx sfx
      pfx=$(printf "%s" "$s" | cut -c1-2)
      sfx=$(printf "%s" "$s" | tail -c 3 2>/dev/null || true)
      printf "%s%s%s" "$pfx" "$(printf "%*s" $(( n-4 )) | tr ' ' '*')" "$sfx"
    fi
  fi
}
timestamp() { date +"%Y%m%d-%H%M%S"; }

echo "==> Contacting Keycloak at: $BASE_URL  (realm=$REALM)"
echo "==> Admin API via:          $ADMIN_URL"
echo "==> Using VAULT_ADDR:       $VAULT_ADDR"

# -------------------------------
# TLS-aware curl wrappers
# -------------------------------
CURL_TLS_ARGS=()
[ -n "$VAULT_CACERT" ] && [ -f "$VAULT_CACERT" ] && CURL_TLS_ARGS+=( --cacert "$VAULT_CACERT" )
if [ -n "$CURL_FORCE_RESOLVE" ]; then
  IFS=';' read -r -a _resolves <<<"$CURL_FORCE_RESOLVE"
  for _r in "${_resolves[@]}"; do
    [ -n "$_r" ] && CURL_TLS_ARGS+=( --resolve "$_r" )
  done
fi
vcurl() { curl -sS "${CURL_TLS_ARGS[@]}" "$@"; }

# -------------------------------
# Keycloak auth + helpers
# -------------------------------
kc_token() {
  # NOTE: admin token from ADMIN_URL (direct KC), not via proxy
  curl -sS -X POST \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    "$ADMIN_URL/realms/master/protocol/openid-connect/token" \
    --data "client_id=admin-cli&username=${KC_ADMIN_USER}&password=${KC_ADMIN_PASS}&grant_type=password" \
  | jq -r '.access_token // empty'
}

KC_TOKEN=""
if "$DRY_RUN"; then
  echo "(dry-run) Skipping Keycloak login."
else
  KC_TOKEN="$(kc_token || true)"
  [[ -z "$KC_TOKEN" ]] && { echo "ERROR: could not obtain Keycloak admin token (is Keycloak up? creds ok?)"; exit 1; }
fi

kc_auth=()
if [[ -n "${KC_TOKEN:-}" ]]; then
  kc_auth=(-H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json; charset=utf-8" -H "Accept: application/json")
fi
# Admin calls go to ADMIN_URL
KC() { curl -sS "${kc_auth[@]}" "$@"; }
KC_POST() { curl -sS -X POST "${kc_auth[@]}" "$@"; }
KC_PUT()  { curl -sS -X PUT  "${kc_auth[@]}" "$@"; }
KC_DEL()  { curl -sS -X DELETE "${kc_auth[@]}" "$@"; }

# -------------------------------
# 1) Realm (create or update)
# -------------------------------
if "$DRY_RUN"; then
  echo "(dry-run) Would create/update realm '$REALM'."
else
  realm_get_code="$(curl -sS -o /tmp/realm.json -w '%{http_code}' "${kc_auth[@]}" "$ADMIN_URL/admin/realms/$REALM" || true)"
  if [[ "$realm_get_code" != "200" ]]; then
    echo "Creating realm '$REALM'…"
    KC_POST "$ADMIN_URL/admin/realms" --data @- <<JSON
{"realm":"$REALM","enabled":true,
 "loginWithEmailAllowed":true,"verifyEmail":false,"sslRequired":"external",
 "accessTokenLifespan":300,"ssoSessionIdleTimeout":1800,"ssoSessionMaxLifespan":28800,"offlineSessionIdleTimeout":2592000,
 "passwordPolicy":"length(12) and lowerCase(1) and upperCase(1) and digits(1) and specialChars(1) and notUsername() and passwordHistory(5)"}
JSON
  else
    echo "Realm '$REALM' exists → updating lifetimes & policy…"
    KC_PUT "$ADMIN_URL/admin/realms/$REALM" --data @- <<JSON
{"accessTokenLifespan":300,"ssoSessionIdleTimeout":1800,"ssoSessionMaxLifespan":28800,"offlineSessionIdleTimeout":2592000,
 "passwordPolicy":"length(12) and lowerCase(1) and upperCase(1) and digits(1) and specialChars(1) and notUsername() and passwordHistory(5)"}
JSON
  fi
fi

# -------------------------------
# 2) Clients (ensure + capture secrets)
# -------------------------------
declare -A CLIENTS=(
  ["${RESOURCE_CLIENT_ID}"]="Config Server (resource server)"
  ["eureka-server"]="Eureka Server (server-to-server)"
  ["danipa-fintech-service"]="Fintech Service (server-to-server)"
)
declare -A SECRETS

if "$DRY_RUN"; then
  echo "(dry-run) Would ensure clients exist and fetch/create secrets."
  for cid in "${!CLIENTS[@]}"; do SECRETS["$cid"]="__DRY_RUN_SECRET__"; done
else
  for cid in "${!CLIENTS[@]}"; do
    name="${CLIENTS[$cid]}"
    list="$(KC "$ADMIN_URL/admin/realms/$REALM/clients?clientId=$cid")"
    id="$(jq -r '.[0].id // empty' <<<"$list")"
    if [[ -z "$id" || "$id" == "null" ]]; then
      echo "Creating client '$cid'…"
      KC_POST "$ADMIN_URL/admin/realms/$REALM/clients" --data @- <<JSON
{"clientId":"$cid","name":"$name","enabled":true,"protocol":"openid-connect",
 "publicClient":false,"serviceAccountsEnabled":true,"directAccessGrantsEnabled":false,
 "standardFlowEnabled":false,"implicitFlowEnabled":false,"authorizationServicesEnabled":false,
 "bearerOnly":false,"attributes":{"access.token.lifespan":"300"},
 "redirectUris":["*"],"webOrigins":["*"]}
JSON
      list="$(KC "$ADMIN_URL/admin/realms/$REALM/clients?clientId=$cid")"
      id="$(jq -r '.[0].id' <<<"$list")"
    else
      echo "Client '$cid' already exists."
    fi
    sec_json="$(KC "$ADMIN_URL/admin/realms/$REALM/clients/$id/client-secret" || true)"
    sec="$(jq -r '.value // empty' <<<"$sec_json")"
    if [[ -z "$sec" || "$sec" == "null" ]]; then
      sec="$(KC_POST "$ADMIN_URL/admin/realms/$REALM/clients/$id/client-secret" | jq -r '.value')"
    fi
    SECRETS["$cid"]="$sec"
  done
fi

# -------------------------------
# 3) Scope (create) + audience mapper on SCOPE (optional/helper)
# -------------------------------
if "$DRY_RUN"; then
  echo "(dry-run) Would ensure client-scope '$SCOPE_NAME' and audience mapper."
else
  SCOPE_ID="$(KC "$ADMIN_URL/admin/realms/$REALM/client-scopes?name=$SCOPE_NAME" | jq -r '.[0].id // empty')"
  if [[ -z "$SCOPE_ID" || "$SCOPE_ID" == "null" ]]; then
    echo "Creating client scope '$SCOPE_NAME'…"
    KC_POST "$ADMIN_URL/admin/realms/$REALM/client-scopes" --data @- <<JSON
{"name":"$SCOPE_NAME","protocol":"openid-connect",
 "attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"}}
JSON
    SCOPE_ID="$(KC "$ADMIN_URL/admin/realms/$REALM/client-scopes?name=$SCOPE_NAME" | jq -r '.[0].id')"
  else
    echo "Client scope '$SCOPE_NAME' already exists."
  fi

  # Remove any previous hardcoded scope claim on the scope itself
  HARD_MAPPER="scope:$SCOPE_NAME"
  existing_maps="$(KC "$ADMIN_URL/admin/realms/$REALM/client-scopes/$SCOPE_ID/protocol-mappers/models")"
  hard_id="$(jq -r --arg n "$HARD_MAPPER" '.[] | select(.name==$n) | .id // empty' <<<"$existing_maps")"
  if [[ -n "$hard_id" ]]; then
    echo "Removing hardcoded scope-claim mapper '$HARD_MAPPER' from scope…"
    KC_DEL "$ADMIN_URL/admin/realms/$REALM/client-scopes/$SCOPE_ID/protocol-mappers/models/$hard_id" >/dev/null 2>&1 || true
  fi

  # Optional audience mapper on the scope (nice-to-have)
  SCOPE_AUD_MAPPER="aud:$RESOURCE_CLIENT_ID"
  has_scope_aud="$(jq -r --arg n "$SCOPE_AUD_MAPPER" 'map(select(.name==$n))|length' <<<"$existing_maps")"
  if [[ "$has_scope_aud" == "0" ]]; then
    echo "Adding Audience mapper '$SCOPE_AUD_MAPPER' to scope (optional)…"
    KC_POST "$ADMIN_URL/admin/realms/$REALM/client-scopes/$SCOPE_ID/protocol-mappers/models" --data @- <<JSON >/dev/null
{"name":"$SCOPE_AUD_MAPPER","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper",
 "config":{"included.client.audience":"$RESOURCE_CLIENT_ID","id.token.claim":"false","access.token.claim":"true",
           "add.to.id.token":"false","add.to.access.token":"true"}}
JSON
  fi
fi

# -------------------------------
# 3b) Audience mapper on CALLER clients (CRITICAL)
# -------------------------------
if ! "$DRY_RUN"; then
  IFS=' ' read -r -a CALLER_CLIENTS <<<"$CALLER_CLIENTS_STR"
  for caller in "${CALLER_CLIENTS[@]}"; do
    echo "Ensuring audience mapper (aud: $RESOURCE_CLIENT_ID) on caller client: $caller"
    cid_json="$(KC "$ADMIN_URL/admin/realms/$REALM/clients?clientId=$caller")"
    cid="$(jq -r '.[0].id // empty' <<<"$cid_json")"
    if [[ -z "$cid" || "$cid" == "null" ]]; then
      echo "  ! WARN: caller client '$caller' not found"
      continue
    fi
    existing="$(KC "$ADMIN_URL/admin/realms/$REALM/clients/$cid/protocol-mappers/models")"
    has_aud="$(jq -r --arg n "aud:$RESOURCE_CLIENT_ID" 'map(select(.name==$n))|length' <<<"$existing")"
    if [[ "$has_aud" == "0" ]]; then
      KC_POST "$ADMIN_URL/admin/realms/$REALM/clients/$cid/protocol-mappers/models" --data @- <<JSON >/dev/null
{
  "name": "aud:$RESOURCE_CLIENT_ID",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-audience-mapper",
  "config": {
    "included.client.audience": "$RESOURCE_CLIENT_ID",
    "id.token.claim": "false",
    "access.token.claim": "true",
    "add.to.id.token": "false",
    "add.to.access.token": "true"
  }
}
JSON
      echo "  + mapper created"
    else
      echo "  = mapper already present"
    fi
  done
fi

# -------------------------------
# 3c) Cosmetic mapper: show scope="config.read" in client_credentials tokens
# -------------------------------
if ! "$DRY_RUN"; then
  IFS=' ' read -r -a CALLER_CLIENTS <<<"$CALLER_CLIENTS_STR"
  for caller in "${CALLER_CLIENTS[@]}"; do
    cid_json="$(KC "$ADMIN_URL/admin/realms/$REALM/clients?clientId=$caller")"
    cid="$(jq -r '.[0].id // empty' <<<"$cid_json")"
    if [[ -z "$cid" || "$cid" == "null" ]]; then
      echo "  ! WARN: caller client '$caller' not found (skip scope-visibility mapper)"
      continue
    fi
    existing="$(KC "$ADMIN_URL/admin/realms/$REALM/clients/$cid/protocol-mappers/models")"
    MAPPER_NAME="scope:$SCOPE_NAME (visibility)"
    has_scope_vis="$(jq -r --arg n "$MAPPER_NAME" 'map(select(.name==$n))|length' <<<"$existing")"
    if [[ "$has_scope_vis" == "0" ]]; then
      echo "Adding scope visibility mapper on '$caller' → scope='$SCOPE_NAME'"
      KC_POST "$ADMIN_URL/admin/realms/$REALM/clients/$cid/protocol-mappers/models" --data @- <<JSON >/dev/null
{
  "name": "$MAPPER_NAME",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-hardcoded-claim-mapper",
  "config": {
    "claim.name": "scope",
    "claim.value": "$SCOPE_NAME",
    "jsonType.label": "String",
    "id.token.claim": "false",
    "access.token.claim": "true",
    "userinfo.token.claim": "false"
  }
}
JSON
    else
      echo "  = scope visibility mapper already present on '$caller'"
    fi
  done
fi

# -------------------------------
# 4) Attach scope to callers & VERIFY (clean logs)
# -------------------------------
verify_scope_link_optional() {
  local cuid="$1"
  local list
  list="$(KC "$ADMIN_URL/admin/realms/$REALM/clients/$cuid/optional-client-scopes")"
  jq -e --arg n "$SCOPE_NAME" 'map(select(.name==$n))|length>0' <<<"$list" >/dev/null
}

verify_scope_link_default() {
  local cuid="$1"
  local list
  list="$(KC "$ADMIN_URL/admin/realms/$REALM/clients/$cuid/default-client-scopes")"
  jq -e --arg n "$SCOPE_NAME" 'map(select(.name==$n))|length>0' <<<"$list" >/dev/null
}

if ! "$DRY_RUN"; then
  IFS=' ' read -r -a CALLER_CLIENTS <<<"$CALLER_CLIENTS_STR"

  # Ensure we have SCOPE_ID from section 3
  if [[ -z "${SCOPE_ID:-}" || "$SCOPE_ID" == "null" ]]; then
    SCOPE_ID="$(KC "$ADMIN_URL/admin/realms/$REALM/client-scopes?name=$SCOPE_NAME" | jq -r '.[0].id // empty')"
    [[ -z "$SCOPE_ID" ]] && { echo "ERROR: scope '$SCOPE_NAME' not found after creation."; exit 1; }
  fi

  for caller in "${CALLER_CLIENTS[@]}"; do
    cid_json="$(KC "$ADMIN_URL/admin/realms/$REALM/clients?clientId=$caller")"
    cid="$(jq -r '.[0].id // empty' <<<"$cid_json")"
    [[ -z "$cid" || "$cid" == "null" ]] && { echo "WARN: caller client '$caller' not found (skipping attach)"; continue; }

    # Try OPTIONAL (preferred)
    KC_POST "$ADMIN_URL/admin/realms/$REALM/clients/$cid/optional-client-scopes/$SCOPE_ID" >/dev/null 2>&1 || true

    if verify_scope_link_optional "$cid"; then
      echo "Attached '$SCOPE_NAME' to '$caller' as OPTIONAL."
      continue
    fi

    # Optional fallback to DEFAULT (user-controlled)
    if [[ "${FORCE_SCOPE_DEFAULT_ON_MISS}" == "true" || "${SCOPE_AS_DEFAULT}" == "true" ]]; then
      KC_POST "$ADMIN_URL/admin/realms/$REALM/clients/$cid/default-client-scopes/$SCOPE_ID" >/dev/null 2>&1 || true
      if verify_scope_link_default "$cid"; then
        echo "Attached '$SCOPE_NAME' to '$caller' as DEFAULT."
      else
        echo "ERROR: could not attach '$SCOPE_NAME' to '$caller' (DEFAULT). Check Keycloak logs."
      fi
    else
      echo "ERROR: '$SCOPE_NAME' not present on '$caller' after OPTIONAL attach."
    fi
  done
fi

# Do NOT add to realm default client scopes unless explicitly requested
if ! "$DRY_RUN"; then
  if [[ "${REALM_DEFAULT_SCOPE}" == "true" ]]; then
    realm_defaults="$(KC "$ADMIN_URL/admin/realms/$REALM/default-default-client-scopes")"
    is_present="$(jq -r --arg name "$SCOPE_NAME" 'map(select(.name==$name))|length' <<<"$realm_defaults")"
    if [[ "$is_present" == "0" ]]; then
      curl -sS -o /dev/null -w '' -X PUT "${kc_auth[@]}" \
        "$ADMIN_URL/admin/realms/$REALM/default-default-client-scopes/$SCOPE_ID" || true
    fi
  else
    echo "Leaving realm default scopes unchanged (recommended)."
  fi
fi

# -------------------------------
# 5) Realm role (authoritative for client_credentials) + grant to callers
# -------------------------------
if "$DRY_RUN"; then
  echo "(dry-run) Would ensure realm role '$SCOPE_NAME' and grant to caller service accounts."
else
  role_name="$SCOPE_NAME"
  role_code="$(curl -sS -o /tmp/role.json -w '%{http_code}' "${kc_auth[@]}" \
               "$ADMIN_URL/admin/realms/$REALM/roles/$role_name" || true)"
  if [[ "$role_code" != "200" ]]; then
    echo "Creating realm role '$role_name'…"
    KC_POST "$ADMIN_URL/admin/realms/$REALM/roles" \
      --data "{\"name\":\"$role_name\",\"description\":\"Read access to config endpoints\"}" \
      >/dev/null
  fi
  ROLE_ID="$(KC "$ADMIN_URL/admin/realms/$REALM/roles/$role_name" | jq -r '.id')"

  IFS=' ' read -r -a CALLER_CLIENTS <<<"$CALLER_CLIENTS_STR"
  for caller in "${CALLER_CLIENTS[@]}"; do
    cid="$(KC "$ADMIN_URL/admin/realms/$REALM/clients?clientId=$caller" | jq -r '.[0].id // empty')"
    if [[ -z "$cid" || "$cid" == "null" ]]; then
      echo "  ! WARN: caller client '$caller' not found (skip role grant)"
      continue
    fi
    svc="$(KC "$ADMIN_URL/admin/realms/$REALM/clients/$cid/service-account-user")"
    uid="$(jq -r '.id' <<<"$svc")"
    assigned="$(KC "$ADMIN_URL/admin/realms/$REALM/users/$uid/role-mappings/realm")"
    has_role="$(jq -r --arg rn "$role_name" 'map(select(.name==$rn))|length' <<<"$assigned")"
    if [[ "$has_role" == "0" ]]; then
      echo "Granting realm role '$role_name' to service account for '$caller'…"
      KC_POST "$ADMIN_URL/admin/realms/$REALM/users/$uid/role-mappings/realm" \
        --data "[{\"id\":\"$ROLE_ID\",\"name\":\"$role_name\"}]" >/dev/null
    else
      echo "  = role '$role_name' already on service account for '$caller'"
    fi
  done
fi

# -------------------------------
# 6) Emit realm & client creds
# -------------------------------
issuer_ext="$BASE_URL/realms/$REALM"
jwks_ext="$issuer_ext/protocol/openid-connect/certs"
issuer_int="http://keycloak:8080/realms/$REALM"
jwks_int="$issuer_int/protocol/openid-connect/certs"

echo
echo "== Realm =="
echo "Issuer URI : $issuer_ext"
echo "JWKS URI   : $jwks_ext"
echo
echo "== Realm (inside docker) =="
echo "Issuer (internal) : $issuer_int"
echo "JWKS (internal)   : $jwks_int"
echo
echo "== Client Credentials (captured) =="
for cid in "${!CLIENTS[@]}"; do
  up="$(tr '[:lower:]-' '[:upper:]_' <<<"$cid")"
  echo "${up}_CLIENT_ID=$cid"
  if "$DRY_RUN"; then
    echo "${up}_CLIENT_SECRET=__DRY_RUN_SECRET__"
  else
    echo "${up}_CLIENT_SECRET=${SECRETS[$cid]}"
  fi
  echo
done

# -------------------------------
# 7) Patch seeds JSON (atomic & safe)
# -------------------------------
echo "Updating $SEEDS_FILE with Keycloak endpoints & client secrets…"
mkdir -p "$SEEDS_DIR"
if [[ ! -f "$SEEDS_FILE" || ! -s "$SEEDS_FILE" ]]; then
  printf '{ "paths": {} }\n' > "$SEEDS_FILE"
fi
if ! jq -e 'type=="object" and .paths? // type=="object"' "$SEEDS_FILE" >/dev/null 2>&1; then
  echo "ERROR: $SEEDS_FILE is not a JSON object with a 'paths' object. Aborting."
  exit 1
fi
tmp_in="$(mktemp)"; cp "$SEEDS_FILE" "$tmp_in"
tmp_out="$(mktemp)"
set -- # clear $@ defensively
jq \
  --arg issuer_ext "$issuer_ext" --arg jwks_ext "$jwks_ext" \
  --arg issuer_int "$issuer_int" --arg jwks_int "$jwks_int" \
  --arg eurId "eureka-server"           --arg eurSec "${SECRETS["eureka-server"]:-}" \
  --arg finId "danipa-fintech-service"  --arg finSec "${SECRETS["danipa-fintech-service"]:-}" \
  --arg env "$ENV_NAME" '
  .paths["application/composite"].["SECURITY_JWT_ENABLED"] = "true"
| .paths["application/composite"].["SECURITY_JWT_ALLOWED_ISSUERS"] = ($issuer_int + "," + $issuer_ext)
| .paths["application/composite"].["SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI"]  = $issuer_int
| .paths["application/composite"].["SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI"] = $jwks_int
| .paths["application/composite"].["SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI_EXTERNAL"]  = $issuer_ext
| .paths["application/composite"].["SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_JWK_SET_URI_EXTERNAL"] = $jwks_ext
| .paths["danipa-eureka-server", $env].["SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_CLIENT_ID"]        = $eurId
| .paths["danipa-eureka-server", $env].["SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_CLIENT_SECRET"]    = $eurSec
| .paths["danipa-eureka-server", $env].["SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_ACCESS_TOKEN_URI"] = ($issuer_ext + "/protocol/openid-connect/token")
| .paths["danipa-fintech-service", $env].["SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_CLIENT_ID"]        = $finId
| .paths["danipa-fintech-service", $env].["SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_CLIENT_SECRET"]    = $finSec
| .paths["danipa-fintech-service", $env].["SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_ACCESS_TOKEN_URI"] = ($issuer_ext + "/protocol/openid-connect/token")
' "$tmp_in" > "$tmp_out" || { echo "jq failed; NOT modifying $SEEDS_FILE"; rm -f "$tmp_in" "$tmp_out"; exit 1; }
if "$DRY_RUN"; then
  if [[ -s "$SEEDS_FILE" ]]; then
    bak="$SEEDS_FILE.bak.$(timestamp)"; cp -p "$SEEDS_FILE" "$bak"
    echo "Backup: saved $SEEDS_FILE -> $bak"
  fi
  echo "(dry-run) Seeds would be updated (no file changed)."
else
  if [[ -s "$SEEDS_FILE" ]]; then
    cp -p "$SEEDS_FILE" "$SEEDS_FILE.bak.$(timestamp)"
  fi
  mv "$tmp_out" "$SEEDS_FILE"
  echo "Seeds updated."
fi
rm -f "$tmp_in" "$tmp_out"

# -------------------------------
# 8) Vault seeding / verify
# -------------------------------
TOKEN="${TOKEN:-$( [[ -f infra/vault/keys/vault-keys.json ]] && jq -r '.root_token' infra/vault/keys/vault-keys.json || echo "" )}"
if "$DRY_RUN"; then
  :
else
  echo "==> VAULT_ADDR=$VAULT_ADDR  MOUNT=$MOUNT  SEEDS_DIR=$SEEDS_DIR"
  [[ -z "$TOKEN" ]] && { echo "ERROR: set TOKEN env var or provide infra/vault/keys/vault-keys.json"; exit 2; }
  TOKEN="$TOKEN" VAULT_ADDR="$VAULT_ADDR" MOUNT="$MOUNT" SEEDS_DIR="$SEEDS_DIR" \
  VAULT_CACERT="$VAULT_CACERT" CURL_FORCE_RESOLVE="$CURL_FORCE_RESOLVE" \
    bash "$WRITE_SECRETS"
fi

# -------------------------------
# 9) Quick verification (tokens + gated endpoint)
# -------------------------------
echo
echo "== Quick verification =="
KC="$ADMIN_URL"   # direct KC for token minting during verification
CALLERS=($CALLER_CLIENTS_STR)

# export the secrets that were printed above (or pulled from seeds)
export EUREKA_SERVER_CLIENT_SECRET="${SECRETS["eureka-server"]:-}"
export DANIPA_FINTECH_SERVICE_CLIENT_SECRET="${SECRETS["danipa-fintech-service"]:-}"

for CID in "${CALLERS[@]}"; do
  case "$CID" in
    eureka-server)          SEC="$EUREKA_SERVER_CLIENT_SECRET" ;;
    danipa-fintech-service) SEC="$DANIPA_FINTECH_SERVICE_CLIENT_SECRET" ;;
  esac
  if [ -z "$SEC" ]; then echo "!! Missing secret for $CID"; continue; fi

  echo "--- $CID (no requested scope) ---"
  RAW=$(curl -s -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d grant_type=client_credentials -d client_id="$CID" -d client_secret="$SEC")
  TOKEN=$(echo "$RAW" | jq -r '.access_token // empty')
  if [ -z "$TOKEN" ]; then echo "$RAW" | jq .; continue; fi
  cut -d. -f2 <<<"$TOKEN" | tr '_-' '/+' | base64 -d 2>/dev/null \
    | jq '{azp, aud, scope, roles: .realm_access.roles}'
  echo -n "health-gated → "
  curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" "$HEALTH_URL"

  echo "--- $CID (request scope=$SCOPE_NAME) ---"
  RAW2=$(curl -s -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d grant_type=client_credentials -d client_id="$CID" -d client_secret="$SEC" \
    -d scope="$SCOPE_NAME")
  if [ "$(jq -r '.error // empty' <<<"$RAW2")" = "invalid_scope" ]; then
    echo "  (Note) Keycloak rejected requested scope — check the attach status above. Token will still be valid via realm role."
  else
    TOKEN2=$(echo "$RAW2" | jq -r '.access_token // empty')
    if [ -n "$TOKEN2" ]; then
      cut -d. -f2 <<<"$TOKEN2" | tr '_-' '/+' | base64 -d 2>/dev/null \
        | jq '{azp, aud, scope, roles: .realm_access.roles}'
      echo -n "health-gated (scoped) → "
      curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN2" "$HEALTH_URL"
    else
      echo "$RAW2" | jq .
    fi
  fi
done

echo
echo "Bootstrap complete."
echo "SCOPE_AS_DEFAULT=${SCOPE_AS_DEFAULT}  REALM_DEFAULT_SCOPE=${REALM_DEFAULT_SCOPE}  FORCE_SCOPE_DEFAULT_ON_MISS=${FORCE_SCOPE_DEFAULT_ON_MISS}  (caller clients: ${CALLER_CLIENTS_STR})"
