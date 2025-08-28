param(
  [string]$ConfigContainer = "danipa-config-server",
  [string]$CfgUser = "CHANGE_ME",
  [string]$CfgPass = "CHANGE_ME",
  [string]$VaultAddr = "http://127.0.0.1:18300",
  [string]$RoleId = "",
  [string]$SecretId = "",
  [string]$AppName = "danipa-fintech-service",
  [string]$ConfigBase = "http://localhost:8088"
)

Write-Host "==> Checking inside container: $ConfigContainer"

# 1) Show key env vars INSIDE the config-server container
#    Use 'printenv | egrep ...' to avoid any $ escaping pitfalls.
docker exec $ConfigContainer sh -lc "printenv | egrep '^(SPRING_PROFILES_ACTIVE|GIT_USER|GIT_TOKEN|VAULT_HOST|VAULT_PORT|CONFIG_GIT_URI|CONFIG_DEFAULT_LABEL)='" 2>$null

# 2) Show whether a temp clone exists (Spring Cloud Config clones to /tmp/config-repo-*)
Write-Host "`n==> Listing /tmp and any /tmp/config-repo-* clones"
docker exec $ConfigContainer sh -lc 'ls -la /tmp; ls -la /tmp/config-repo-* 2>/dev/null || true'

# 3) Show a few lines around app startup to confirm profile and composite wiring
Write-Host "`n==> Recent Config Server logs (last 200 lines)"
docker logs --tail 200 $ConfigContainer 2>$null

# 4) Hit actuator/env to inspect wiring (from host, using Basic auth)
$pair  = "$CfgUser`:$CfgPass"
$basic = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))

Write-Host "`n==> GET $ConfigBase/actuator/env (looking for composite+git settings)"
try {
  $envView = Invoke-RestMethod -Uri "$ConfigBase/actuator/env" -Headers @{ Authorization = $basic }
  # Print only the parts we care about to keep output readable
  $props = @(
    "spring.cloud.config.server.composite[0].type",
    "spring.cloud.config.server.composite[0].uri",
    "spring.cloud.config.server.composite[0].search-paths",
    "spring.cloud.config.server.composite[0].username",
    "spring.cloud.config.server.composite[1].type",
    "spring.cloud.config.server.composite[1].host",
    "spring.cloud.config.server.composite[1].port",
    "spring.cloud.config.server.composite[1].profileSeparator",
    "spring.security.user.name"
  )

  foreach ($p in $props) {
    # Walk the object safely
    $val = $envView | ConvertTo-Json -Depth 100 | ConvertFrom-Json |
      Select-Object -ExpandProperty propertySources -ErrorAction SilentlyContinue |
      ForEach-Object {
        $_.properties.$p.value
      } | Where-Object { $_ } | Select-Object -First 1
    if ($val) { "{0} = {1}" -f $p, $val } else { "{0} = (not found in env view)" -f $p }
  }
}
catch {
  Write-Warning "actuator/env request failed: $($_.Exception.Message)"
}

# 5) If RoleId+SecretId provided, login to Vault to get X-Config-Token
$hvs = $null
if ($RoleId -and $SecretId) {
  Write-Host "`n==> AppRole login to Vault ($VaultAddr) to obtain X-Config-Token"
  try {
    $login = Invoke-RestMethod -Method POST `
      -Uri "$VaultAddr/v1/auth/approle/login" `
      -ContentType 'application/json' `
      -Body (@{ role_id=$RoleId; secret_id=$SecretId } | ConvertTo-Json)
    $hvs = $login.auth.client_token
    Write-Host "   Got token: $($hvs.Substring(0,14))..."
  } catch {
    Write-Warning "   Vault AppRole login failed: $($_.Exception.Message)"
  }
} else {
  Write-Warning "   Skipping Vault login (RoleId/SecretId not provided)."
}

# 6) Probe the Config Server endpoints
function Try-Config {
  param([string]$Uri, [bool]$WithVault)

  $hdrs = @{ Authorization = $basic }
  if ($WithVault -and $hvs) { $hdrs["X-Config-Token"] = $hvs }

  Write-Host "`nGET $Uri" -ForegroundColor Cyan
  if ($WithVault -and -not $hvs) { Write-Host "   (no X-Config-Token available)" }

  try {
    $res = Invoke-RestMethod -Uri $Uri -Headers $hdrs
    # Print just the propertySources names
    $names = $res.propertySources | ForEach-Object { $_.name }
    Write-Host "   OK. propertySources:" -ForegroundColor Green
    $names | ForEach-Object { Write-Host "   - $_" }
  } catch {
    Write-Warning "   FAILED: $($_.Exception.Message)"
  }
}

Try-Config "$ConfigBase/$AppName/default" $false
Try-Config "$ConfigBase/$AppName/dev"     $true

Write-Host "`n==> Done."
