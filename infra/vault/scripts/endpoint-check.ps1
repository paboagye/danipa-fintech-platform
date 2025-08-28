param(
  [string]$VaultUri   = "http://127.0.0.1:18300",
  [string]$ConfigBase = "http://localhost:8088",
  [string]$App        = "danipa-fintech-service",
  [string]$Label      = "main",
  [string]$ConfigUser = "CHANGE_ME",  # your config-server user
  [string]$ConfigPass = "CHANGE_ME",
  [string]$RoleId,
  [string]$SecretId
)

if (-not $RoleId -or -not $SecretId) { throw "Provide -RoleId and -SecretId (from your AppRole)." }

# 1) Login to Vault via AppRole
$login = Invoke-RestMethod -Method POST `
  -Uri "$VaultUri/v1/auth/approle/login" `
  -ContentType 'application/json' `
  -Body (@{ role_id=$RoleId; secret_id=$SecretId } | ConvertTo-Json)
$hvs = $login.auth.client_token

# 2) Basic auth for Config Server
$pair  = "$ConfigUser:$ConfigPass"
$basic = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))

function Try-Get([string]$url, [hashtable]$headers) {
  try {
    $r = Invoke-RestMethod -Uri $url -Headers $headers
    Write-Host "OK  $url"
    return ,$r
  } catch {
    Write-Warning "ERR $url -> $($_.Exception.Message)"
    return $null
  }
}

# 3) Hit endpoints
$hNoVault = @{ Authorization = $basic }
$hVault   = @{ Authorization = $basic; "X-Config-Token" = $hvs }

Write-Host "==> GET $ConfigBase/$App/default (no Vault header)"
$r1 = Try-Get "$ConfigBase/$App/default" $hNoVault

Write-Host "==> GET $ConfigBase/$App/dev (with X-Config-Token)"
$r2 = Try-Get "$ConfigBase/$App/dev"     $hVault

Write-Host "==> GET $ConfigBase/$App/dev/$Label (with X-Config-Token + label)"
$r3 = Try-Get "$ConfigBase/$App/dev/$Label" $hVault

# Quick summary
foreach ($r in @($r1,$r2,$r3)) {
  if ($null -ne $r) {
    $names = $r.propertySources | ForEach-Object { $_.name }
    Write-Host "   propertySources:" ($names -join " | ")
  }
}
