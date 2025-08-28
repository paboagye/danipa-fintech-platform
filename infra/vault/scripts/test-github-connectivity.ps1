# Put your PAT in a variable (don’t commit this!)
$PAT = 'CHANGE_ME'

# Preferred: Bearer header
Invoke-RestMethod https://api.github.com/user `
  -Headers @{ Authorization = "Bearer $PAT"; "User-Agent" = "cred-check" }

# Alternative: Basic with username + PAT as password
$pair  = "paboagye:$PAT"
$basic = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
Invoke-RestMethod https://api.github.com/user `
  -Headers @{ Authorization = $basic; "User-Agent" = "cred-check" }
