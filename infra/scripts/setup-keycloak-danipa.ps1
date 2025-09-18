param(
  [string]$Base = "http://localhost:8082",
  [string]$AdminUser = "admin",
  [string]$AdminPass = "admin",
  [string]$Realm = "danipa",
  # Clients to ensure (clientId => friendly name)
  [hashtable]$Clients = @{
    "config-server"        = "Config Server (server-to-server)"
    "eureka-server"        = "Eureka Server (server-to-server)"
    "danipa-fintech-service" = "Fintech Service (server-to-server)"
  },
  [switch]$RotateSecret
)

# ---------------- helpers ----------------
function Get-AdminHeaders {
  $tok = Invoke-RestMethod -Method POST -Uri "$Base/realms/master/protocol/openid-connect/token" `
    -ContentType "application/x-www-form-urlencoded" `
    -Body @{ client_id="admin-cli"; username=$AdminUser; password=$AdminPass; grant_type="password" }
  if (-not $tok.access_token) { throw "Could not obtain admin token. Check credentials & Keycloak availability." }
  return @{
    Authorization = "Bearer $($tok.access_token)"
    Accept        = "application/json"
  }
}

# Always send JSON as UTF-8 bytes (KC sometimes chokes on UTF-16)
function Invoke-KcJson {
  param(
    [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','DELETE','PATCH')]$Method,
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory)][hashtable]$Headers,
    $BodyObject = $null,
    [string]$RawJson = $null
  )
  if ($RawJson) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($RawJson)
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ContentType 'application/json; charset=utf-8' -Body $bytes
  } elseif ($BodyObject -ne $null) {
    $json  = $BodyObject | ConvertTo-Json -Depth 50 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ContentType 'application/json; charset=utf-8' -Body $bytes
  } else {
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
  }
}

function Try-Get($Method, $Uri, $Headers) {
  try { return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ErrorAction Stop }
  catch { return $null }
}

$h = Get-AdminHeaders

# ---------------- 1) Realm create/update (policy + lifetimes) ----------------
$existingRealm = Try-Get GET "$Base/admin/realms/$Realm" $h
if (-not $existingRealm) {
  Write-Host "Creating realm '$Realm'..."
  $realmBody = @{
    realm   = $Realm
    enabled = $true
    loginWithEmailAllowed = $true
    verifyEmail           = $false
    sslRequired           = "external"
    accessTokenLifespan       = 300
    ssoSessionIdleTimeout     = 1800
    ssoSessionMaxLifespan     = 28800
    offlineSessionIdleTimeout = 2592000
    passwordPolicy = "length(12) and lowerCase(1) and upperCase(1) and digits(1) and specialChars(1) and notUsername() and passwordHistory(5)"
  }
  Invoke-KcJson -Method POST -Uri "$Base/admin/realms" -Headers $h -BodyObject $realmBody | Out-Null
  Write-Host "Realm '$Realm' created."
} else {
  Write-Host "Realm '$Realm' already exists. Applying policy & lifetimes…"
  $update = @{
    accessTokenLifespan       = 300
    ssoSessionIdleTimeout     = 1800
    ssoSessionMaxLifespan     = 28800
    offlineSessionIdleTimeout = 2592000
    passwordPolicy            = "length(12) and lowerCase(1) and upperCase(1) and digits(1) and specialChars(1) and notUsername() and passwordHistory(5)"
  }
  Invoke-KcJson -Method PUT -Uri "$Base/admin/realms/$Realm" -Headers $h -BodyObject $update | Out-Null
}

# ---------------- 2) Realm role (config.read) ----------------
$roleName = "config.read"
$role = Try-Get GET "$Base/admin/realms/$Realm/roles/$roleName" $h
if (-not $role) {
  Write-Host "Creating role '$roleName'…"
  Invoke-KcJson -Method POST -Uri "$Base/admin/realms/$Realm/roles" -Headers $h `
    -BodyObject @{ name = $roleName; description = "Read access to config endpoints" } | Out-Null
  $role = Invoke-RestMethod -Method GET -Uri "$Base/admin/realms/$Realm/roles/$roleName" -Headers $h
} else {
  Write-Host "Role '$roleName' already exists."
}

# ---------------- 3) Ensure a confidential client + service account + secret + role grant ----------------
function Ensure-ConfidentialClient {
  param(
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$DisplayName
  )

  $found = Try-Get GET "$Base/admin/realms/$Realm/clients?clientId=$ClientId" $h
  $client = if ($found -and $found.Count -gt 0) { $found[0] } else { $null }

  if (-not $client) {
    Write-Host "Creating client '$ClientId'…"
    $body = @{
      clientId                     = $ClientId
      name                         = $DisplayName
      enabled                      = $true
      protocol                     = "openid-connect"
      publicClient                 = $false              # confidential
      serviceAccountsEnabled       = $true
      directAccessGrantsEnabled    = $false
      standardFlowEnabled          = $false
      implicitFlowEnabled          = $false
      authorizationServicesEnabled = $false
      bearerOnly                   = $false
      attributes = @{ "access.token.lifespan" = "300" }
      redirectUris = @("*")
      webOrigins   = @("*")
    }
    Invoke-KcJson -Method POST -Uri "$Base/admin/realms/$Realm/clients" -Headers $h -BodyObject $body | Out-Null
    $client = (Invoke-RestMethod -Method GET -Uri "$Base/admin/realms/$Realm/clients?clientId=$ClientId" -Headers $h)[0]
  } else {
    Write-Host "Client '$ClientId' already exists."
  }

  # Service account for client
  $svcUser = Invoke-RestMethod -Method GET -Uri "$Base/admin/realms/$Realm/clients/$($client.id)/service-account-user" -Headers $h

  # Assign realm role if missing
  $assigned = Invoke-RestMethod -Method GET -Uri "$Base/admin/realms/$Realm/users/$($svcUser.id)/role-mappings/realm" -Headers $h
  $hasRole  = $false
  if ($assigned) { $hasRole = ($assigned | Where-Object { $_.name -eq $roleName }) -ne $null }
  if (-not $hasRole) {
    Write-Host "Granting '$roleName' to service account for '$ClientId'…"
    $bodyJson = "[{`"id`":`"$($role.id)`",`"name`":`"$($role.name)`"}]"
    Invoke-KcJson -Method POST `
      -Uri "$Base/admin/realms/$Realm/users/$($svcUser.id)/role-mappings/realm" `
      -Headers $h -RawJson $bodyJson | Out-Null
  }

  # Secret (rotate or read)
  $secretValue = $null
  if ($RotateSecret) {
    Write-Host "Rotating secret for '$ClientId'…"
    $secretValue = (Invoke-RestMethod -Method POST -Uri "$Base/admin/realms/$Realm/clients/$($client.id)/client-secret" -Headers $h).value
  } else {
    $getSecret = Try-Get GET "$Base/admin/realms/$Realm/clients/$($client.id)/client-secret" $h
    $secretValue = if ($getSecret -and $getSecret.value) { $getSecret.value } `
                   else { (Invoke-RestMethod -Method POST -Uri "$Base/admin/realms/$Realm/clients/$($client.id)/client-secret" -Headers $h).value }
  }

  # Return a small object for output
  return [pscustomobject]@{
    clientId = $ClientId
    secret   = $secretValue
  }
}

# Ensure all clients
$results = @()
foreach ($kv in $Clients.GetEnumerator()) {
  $results += Ensure-ConfidentialClient -ClientId $kv.Key -DisplayName $kv.Value
}

# ---------------- Print wiring info ----------------
$issuer = "$Base/realms/$Realm"
$jwks   = "$issuer/protocol/openid-connect/certs"

Write-Host ""
Write-Host "== Realm =="
Write-Host "Issuer URI : $issuer"
Write-Host "JWKS URI   : $jwks"
Write-Host ""

Write-Host "== Client Credentials (store in Vault / env) =="
foreach ($r in $results) {
  Write-Host ("{0}_CLIENT_ID={1}" -f ($r.clientId -replace '-','_' | ForEach-Object { $_.ToUpper() }), $r.clientId)
  Write-Host ("{0}_CLIENT_SECRET={1}" -f ($r.clientId -replace '-','_' | ForEach-Object { $_.ToUpper() }), $r.secret)
  Write-Host ""
}

Write-Host "Grant needed in Config Server: scope 'config.read' (already set as realm role)."
