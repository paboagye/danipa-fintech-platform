param(
  [string]$JsonPath = "..\seeds\dev.json",
  [string]$VaultUri = "http://127.0.0.1:18300",
  [string]$Token    = "CHANGE_ME",
  [string]$Mount    = "secret"   # KV v2 mount name
)

Write-Host "==> Writing secrets to Vault ($VaultUri) using KV v2 (mount=$Mount)"
Write-Host "Token: $Token`n"

if (!(Test-Path -LiteralPath $JsonPath)) {
  throw "JSON file not found: $JsonPath"
}

$json = Get-Content -Raw -LiteralPath $JsonPath | ConvertFrom-Json

if (-not $json.paths) {
  throw "JSON must contain a top-level 'paths' object."
}

foreach ($prop in $json.paths.PSObject.Properties) {
  $path = [string]$prop.Name
  $data = $prop.Value

  if (-not $path) { continue }
  if ($null -eq $data) { $data = @{} }

  # convert PSCustomObject -> hashtable
  $hashtable = @{}
  foreach ($p in $data.PSObject.Properties) {
    $hashtable[$p.Name] = $p.Value
  }

  $uri  = "$VaultUri/v1/$Mount/data/$path"
  $body = @{ data = $hashtable } | ConvertTo-Json -Depth 20

  try {
    Invoke-RestMethod -Method POST -Uri $uri `
      -Headers @{ "X-Vault-Token" = $Token } `
      -ContentType 'application/json' -Body $body | Out-Null
    Write-Host "WROTE: $Mount/data/$path"
  }
  catch {
    Write-Warning "FAILED: $Mount/data/$path - $($_.Exception.Message)"
  }
}

Write-Host "`n==> Verify read: $Mount/data/danipa-fintech-service,dev"
try {
  $r = Invoke-RestMethod -Method GET -Uri "$VaultUri/v1/$Mount/data/danipa-fintech-service,dev" `
        -Headers @{ "X-Vault-Token" = $Token }
  $keys = ($r.data.data | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
  Write-Host "   keys: $($keys -join ', ')"
}
catch {
  Write-Warning "Verify read failed: $($_.Exception.Message)"
}

Write-Host "`nDone."
