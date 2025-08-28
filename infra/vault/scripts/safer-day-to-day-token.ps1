# --- Vars ---
$VAULT = 'http://127.0.0.1:18300'
$ROOT  = 'CHANGE_ME'   # your root token from vault.init.txt
$headersRoot = @{ 'X-Vault-Token' = $ROOT }

# --- Replace policy with exact paths + wildcards where useful ---
$policy = @'
# danipa/config (exact) and comma-profile variant
path "secret/data/danipa/config"              { capabilities = ["read","list"] }
path "secret/metadata/danipa/config"          { capabilities = ["read","list"] }
path "secret/data/danipa/config,dev"          { capabilities = ["read"] }
path "secret/metadata/danipa/config,dev"      { capabilities = ["read"] }

# danipa-fintech-service,dev (comma key; needs exact)
path "secret/data/danipa-fintech-service,dev"     { capabilities = ["read"] }
path "secret/metadata/danipa-fintech-service,dev" { capabilities = ["read"] }

# (Optional) allow listing under these prefixes if you add nested keys later
path "secret/metadata/danipa/*" { capabilities = ["read","list"] }
'@

Invoke-RestMethod -Method PUT `
  -Uri "$VAULT/v1/sys/policies/acl/config-reader" `
  -Headers $headersRoot -ContentType 'application/json' `
  -Body (@{ policy = $policy } | ConvertTo-Json) | Out-Null

# --- Create a short-lived token bound to that policy ---
$tokResp = Invoke-RestMethod -Method POST `
  -Uri "$VAULT/v1/auth/token/create" `
  -Headers $headersRoot -ContentType 'application/json' `
  -Body (@{ policies = @('config-reader'); ttl = '24h' } | ConvertTo-Json)

$reader = $tokResp.auth.client_token
"Reader token: $reader"
$headersReader = @{ 'X-Vault-Token' = $reader }

# --- Verify each path can be read with the reader token ---
"==> danipa/config"
Invoke-RestMethod -Uri "$VAULT/v1/secret/data/danipa/config" -Headers $headersReader | ConvertTo-Json -Depth 8

"==> danipa/config,dev"
Invoke-RestMethod -Uri "$VAULT/v1/secret/data/danipa/config,dev" -Headers $headersReader | ConvertTo-Json -Depth 8

"==> danipa-fintech-service,dev"
Invoke-RestMethod -Uri "$VAULT/v1/secret/data/danipa-fintech-service,dev" -Headers $headersReader | ConvertTo-Json -Depth 8

# (Optional) sanity check: ask Vault what this token can do on a path
Invoke-RestMethod -Method POST `
  -Uri "$VAULT/v1/sys/capabilities-self" `
  -Headers $headersReader -ContentType 'application/json' `
  -Body (@{ paths = @("secret/data/danipa/config","secret/data/danipa/config,dev","secret/data/danipa-fintech-service,dev") } | ConvertTo-Json) `
| ConvertTo-Json -Depth 8


# Read back current policy text
Invoke-RestMethod -Method GET -Uri "$VAULT/v1/sys/policies/acl/config-reader" -Headers $headersRoot
