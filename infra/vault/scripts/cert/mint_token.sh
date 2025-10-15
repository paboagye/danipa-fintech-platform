chmod +x infra/vault/scripts/cert/mint_stepca_token.sh
# ensure the root is present once:
docker cp infra/vault/tls/root_ca.crt step-ca:/tmp/root_ca.crt

# get a token (prints a JWT)
TOKEN="$(./infra/vault/scripts/cert/mint_stepca_token.sh issue vault.local.danipa.com)"
echo "$TOKEN"
