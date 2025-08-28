$VAULT = "http://127.0.0.1:18300"
$admin = "CHANGE_ME"   # your dev root token (or admin token)

Invoke-RestMethod -Method GET `
  -Uri "$VAULT/v1/secret/data/danipa/config/danipa-fintech-service,dev" `
  -Headers @{ "X-Vault-Token" = $admin }

