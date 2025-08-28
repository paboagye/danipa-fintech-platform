$VAULT  = 'http://127.0.0.1:18300'
$ROOT   = 'CHANGE_ME'   # your root token
$H      = @{ 'X-Vault-Token' = $ROOT }

# enable approle (ok if already enabled)
Invoke-RestMethod -Method POST -Uri "$VAULT/v1/sys/auth/approle" -Headers $H -ContentType 'application/json' -Body (@{ type='approle' } | ConvertTo-Json) | Out-Null

# create/update role used by config-server (bound to your config-reader policy)
Invoke-RestMethod -Method POST -Uri "$VAULT/v1/auth/approle/role/danipa-config-role" `
  -Headers $H -ContentType 'application/json' `
  -Body (@{ token_policies='config-reader'; token_ttl='24h'; token_max_ttl='72h' } | ConvertTo-Json) | Out-Null

# fetch role_id + a fresh secret_id
$roleId   = (Invoke-RestMethod -Method GET  -Uri "$VAULT/v1/auth/approle/role/danipa-config-role/role-id" -Headers $H).data.role_id
$secretId = (Invoke-RestMethod -Method POST -Uri "$VAULT/v1/auth/approle/role/danipa-config-role/secret-id" -Headers $H).data.secret_id

"ROLE_ID  = $roleId"
"SECRET_ID= $secretId"
