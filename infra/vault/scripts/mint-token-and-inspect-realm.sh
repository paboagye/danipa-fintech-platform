# 1) Mint a brand-new token
BASE_URL=http://localhost:8082 REALM=danipa CALLER_CLIENT=danipa-fintech-service
CLIENT_SECRET="BaRQ9xlJSWKs3oZjFJnCNSjHPpe2gkxx"
TOK=$(
  curl -s -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=client_credentials&client_id=$CALLER_CLIENT&client_secret=$CLIENT_SECRET" \
  | jq -r .access_token
)

# 2) Sanity-print the token fields
python3 - <<'PY' "$TOK"
import sys,base64,json
t=sys.argv[1]; pl=json.loads(base64.urlsafe_b64decode(t.split('.')[1]+'=='))
print("iss:", pl.get("iss"))
print("aud:", pl.get("aud"))
print("scope:", pl.get("scope"))
print("realm_access.roles:", (pl.get("realm_access") or {}).get("roles"))
PY

# 3) Hit the gated endpoint immediately
curl -i http://localhost:8088/actuator/health-gated -H "Authorization: Bearer $TOK"


# What the app is actually using (from Vault-seeded props)
#curl -s http://localhost:8088/actuator/env \
# | jq -r '.propertySources[].properties
#    | to_entries[]
#    | select(.key=="spring.security.oauth2.resourceserver.jwt.issuer-uri")
#    | .value.value' | head -1


