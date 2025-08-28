# 1) Basics
$VAULT = 'http://127.0.0.1:18300'
$ADMIN = 'CHANGE_ME'   # dev root token you used to start Vault

# 2) Get the current role_id for your role
$role = Invoke-RestMethod -Method GET `
  -Uri "$VAULT/v1/auth/approle/role/danipa-config-role/role-id" `
  -Headers @{ 'X-Vault-Token' = $ADMIN }
$roleId = $role.data.role_id
Write-Host "  VAULT_ROLE_ID=$roleId"    -ForegroundColor Yellow

# 3) Mint a fresh secret_id for that role
$secret = Invoke-RestMethod -Method POST `
  -Uri "$VAULT/v1/auth/approle/role/danipa-config-role/secret-id" `
  -Headers @{ 'X-Vault-Token' = $ADMIN }
$secretId = $secret.data.secret_id
Write-Host "  VAULT_SECRET_ID=$secretId" -ForegroundColor Yellow