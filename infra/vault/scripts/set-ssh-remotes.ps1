param(
  [string]$Root = "."
)
# Recursively convert all Git remotes named 'origin' to SSH under the given root.
Get-ChildItem -Path $Root -Directory -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
  $gitDir = Join-Path $_.FullName ".git"
  if (Test-Path $gitDir) {
    Push-Location $_.FullName
    try {
      $remotes = git remote -v 2>$null
      if ($LASTEXITCODE -eq 0 -and $remotes -match "github\.com") {
        $origin = (git remote get-url origin)
        if ($origin -match "^https://github\.com/([^/]+)/([^/\.]+)(\.git)?$") {
          $owner = $Matches[1]
          $repo  = $Matches[2]
          $ssh = "git@github.com:$owner/$repo.git"
          git remote set-url origin $ssh
          Write-Host "Updated to SSH:" $_.FullName "->" $ssh
        }
      }
    } catch {
      Write-Warning "Skipping $($_.FullName): $_"
    } finally {
      Pop-Location
    }
  }
}
