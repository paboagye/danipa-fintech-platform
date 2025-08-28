# Values from your environment (.env.dev)
$roleId   = $Env:VAULT_ROLE_ID       # 10c1a5f4-3a82-92a0-94d1-baae354e61a9
$secretId = $Env:VAULT_SECRET_ID     # 9c2f3591-44d0-71d8-04dc-ceb52aabe370

# Host‑side port that forwards to Vault container’s 8200
$vaultUri = 'http://127.0.0.1:18300'

# Build request body
$body = @{
    role_id   = $roleId
    secret_id = $secretId
}

# Log in via AppRole and extract the token
$response = Invoke-RestMethod -Method Post `
    -Uri "$vaultUri/v1/auth/approle/login" `
    -ContentType 'application/json' `
    -Body ($body | ConvertTo-Json)

$currentReaderToken = $response.auth.client_token

Write-Host "Current Vault reader token:" $currentReaderToken


# Build Basic Auth header for config-server
$basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("cfg-user:cfg-pass"))

# Call config‑server for the dev profile using the token
Invoke-RestMethod -Uri "http://localhost:8088/danipa-fintech-service/dev" `
    -Headers @{
        Authorization   = "Basic $basicAuth"
        'X-Config-Token' = $currentReaderToken
    }
