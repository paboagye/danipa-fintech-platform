<#  setup-and-validate.ps1
    - Configures Vault (KV v2, policy, AppRole)
    - Writes base & dev secrets for danipa-fintech-service
    - Logs in via AppRole to get a client token
    - Calls Config Server /{app}/default (no header) and /{app}/dev (with X-Config-Token)
    NOTES:
      * Assumes docker-compose stack is up (Vault on host:18300 -> container:8200).
      * Adjust variables in "User settings" if needed.
#>

# -------------------- User settings --------------------
$VAULT            = 'http://127.0.0.1:18300'  # host-mapped port to Vault (container 8200 -> host 18300)
$VaultRootToken   = 'CHANGE_ME'                    # dev root token (VAULT_DEV_ROOT_TOKEN_ID) for setup steps
$AppName          = 'danipa-fintech-service'  # config service/application name
$ConfigServerBase = 'http://localhost:8088'   # Config Server base URL on host
$CfgUser          = 'CHANGE_ME'
$CfgPass          = 'CHANGE_ME'

# KV mount path we use
$KvMount = 'secret'
# Where Config Server expects keys (based on application.yml defaultKey and profileSeparator=",")
$BaseKey = "danipa/config/$AppName"
$DevKey  = "$BaseKey,dev"

# Some demo values you can replace with your real props
$BaseProps = @{
  "example.base" = "from vault base"
}
$DevProps = @{
  "spring.profiles.active" = "dev"
  "example.message"        = "Hello from Vault DEV"
}

# -------------------- Helpers --------------------
function Wait-HttpOk($url, $timeoutSec = 60) {
  $start = Get-Date
  while ((Get-Date) - $start -lt (New-TimeSpan -Seconds $timeoutSec)) {
    try {
      $r = Invoke-RestMethod -Method GET -Uri $url -TimeoutSec 5
      return $true
    } catch {
      Start-Sleep -Seconds 2
    }
  }
  return $false
}

function Invoke-Vault {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Path,      # e.g. /v1/sys/mounts
    [hashtable]$Body = $null,
    [string]$Token = $VaultRootToken
  )
  $headers = @{ 'X-Vault-Token' = $Token }
  if ($Body) {
    return Invoke-RestMethod -Method $Method -Uri ($VAULT + $Path) -Headers $headers -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 8)
  } else {
    return Invoke-RestMethod -Method $Method -Uri ($VAULT + $Path) -Headers $headers
  }
}

Write-Host "==> Checking Vault availability at $VAULT ..." -ForegroundColor Cyan
if (-not (Wait-HttpOk "$VAULT/v1/sys/health" 60)) {
  Write-Error "Vault is not reachable at $VAULT. Make sure the container is up (host 18300 -> container 8200)."
  exit 1
}

# -------------------- Ensure KV v2 is enabled/tuned at "secret/" --------------------
Write-Host "==> Ensuring KV v2 is enabled at path '$KvMount/' ..." -ForegroundColor Cyan
try {
  # If already mounted, tune to v2; if not, enable + tune
  try {
    Invoke-Vault -Method GET -Path "/v1/sys/mounts/$KvMount"
    $mounted = $true
  } catch { $mounted = $false }

  if (-not $mounted) {
    Invoke-Vault -Method POST -Path "/v1/sys/mounts/$KvMount" -Body @{ type = 'kv'; options = @{ version = '2' } } | Out-Null
    Write-Host "Mounted KV at $KvMount/ (v2)" -ForegroundColor Green
  } else {
    Invoke-Vault -Method POST -Path "/v1/sys/mounts/$KvMount/tune" -Body @{ options = @{ version = '2' } } | Out-Null
    Write-Host "KV mount '$KvMount/' exists; tuned to v2." -ForegroundColor Green
  }
} catch {
  Write-Warning "KV mount step: $($_.Exception.Message) (continuing)"
}

# -------------------- Write Base & Dev secrets --------------------
Write-Host "==> Writing base and dev secrets ..." -ForegroundColor Cyan
Invoke-Vault -Method POST -Path "/v1/$KvMount/data/$BaseKey" -Body @{ data = $BaseProps } | Out-Null
Invoke-Vault -Method POST -Path "/v1/$KvMount/data/$DevKey"  -Body @{ data = $DevProps }  | Out-Null
Write-Host "Wrote:" -ForegroundColor Green
Write-Host "  secret/data/$BaseKey" -ForegroundColor Gray
Write-Host "  secret/data/$DevKey"  -ForegroundColor Gray

# -------------------- Policy: config-reader --------------------
Write-Host "==> Creating/Updating policy 'config-reader' ..." -ForegroundColor Cyan
$policy = @'
path "secret/data/danipa/config/*"     { capabilities = ["read","list"] }
path "secret/metadata/danipa/config/*" { capabilities = ["read","list"] }
'@
Invoke-Vault -Method PUT -Path "/v1/sys/policies/acl/config-reader" -Body @{ policy = $policy } | Out-Null
Write-Host "Policy 'config-reader' ready." -ForegroundColor Green

# -------------------- Enable AppRole & create role --------------------
Write-Host "==> Ensuring AppRole auth method is enabled ..." -ForegroundColor Cyan
try {
  Invoke-Vault -Method POST -Path '/v1/sys/auth/approle' -Body @{ type = 'approle' } | Out-Null
} catch { }  # ignore "already in use"
Write-Host "AppRole auth is enabled." -ForegroundColor Green

Write-Host "==> Creating/Updating role 'danipa-config-role' ..." -ForegroundColor Cyan
Invoke-Vault -Method POST -Path '/v1/auth/approle/role/danipa-config-role' -Body @{
  token_policies = "config-reader"
  token_ttl      = "24h"
  token_max_ttl  = "72h"
} | Out-Null

$roleId  = (Invoke-Vault -Method GET  -Path '/v1/auth/approle/role/danipa-config-role/role-id').data.role_id
$secretId= (Invoke-Vault -Method POST -Path '/v1/auth/approle/role/danipa-config-role/secret-id').data.secret_id

Write-Host "AppRole created. Save these for the Config Server env:" -ForegroundColor Green
Write-Host "  VAULT_ROLE_ID  = $roleId"   -ForegroundColor Yellow
Write-Host "  VAULT_SECRET_ID= $secretId" -ForegroundColor Yellow

# -------------------- Login as AppRole to get a client token --------------------
Write-Host "==> Logging in via AppRole to get client token ..." -ForegroundColor Cyan
$login   = Invoke-RestMethod -Method POST -Uri "$VAULT/v1/auth/approle/login" -ContentType 'application/json' `
  -Body (@{ role_id = $roleId; secret_id = $secretId } | ConvertTo-Json)
$clientToken = $login.auth.client_token
Write-Host "Got client token (hvs.*). Will use it as X-Config-Token." -ForegroundColor Green

# -------------------- Validate Config Server --------------------
Write-Host "==> Validating Config Server endpoints ..." -ForegroundColor Cyan
$pair = "${CfgUser}:${CfgPass}"
$bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
$basic = "Basic " + [Convert]::ToBase64String($bytes)
$headers = @{
  "Authorization"  = $basic
  "X-Config-Token" = $token   # from your AppRole login
}

Write-Host "GET $ConfigServerBase/$AppName/default  (no Vault header; expects GIT/native only)" -ForegroundColor Gray
try {
  $r1 = Invoke-RestMethod -Uri "$ConfigServerBase/$AppName/default" -Headers $hdrNoVault
  Write-Host "OK: default profile returned $(($r1.propertySources | Measure-Object).Count) propertySources." -ForegroundColor Green
} catch {
  Write-Warning "Default profile call failed: $($_.Exception.Message)"
}

Write-Host "GET $ConfigServerBase/$AppName/dev  (with X-Config-Token; expects Vault merge)" -ForegroundColor Gray
try {
  $r2 = Invoke-RestMethod -Uri "$ConfigServerBase/$AppName/dev" -Headers $headers
  Write-Host "OK: dev profile returned $(($r2.propertySources | Measure-Object).Count) propertySources." -ForegroundColor Green
} catch {
  Write-Warning "Dev profile call failed: $($_.Exception.Message)"
  Write-Host "TIP: ensure you wrote secrets to 'secret/data/$DevKey' and the Config Server is using VAULT_HOST=danipa-vault, VAULT_PORT=8200." -ForegroundColor DarkYellow
}

Write-Host "`n==> DONE." -ForegroundColor Cyan
Write-Host "If you want the Config Server container to pick up the AppRole, set its env to:" -ForegroundColor Cyan
Write-Host "  VAULT_HOST=danipa-vault   (service name on the bridge network)" -ForegroundColor Yellow
Write-Host "  VAULT_PORT=8200           (container port; NOT 18300)" -ForegroundColor Yellow
Write-Host "  VAULT_ROLE_ID=$roleId"    -ForegroundColor Yellow
Write-Host "  VAULT_SECRET_ID=$secretId" -ForegroundColor Yellow
