param(
  [string]$Service = "fintech-service"
)

Write-Host "==> Stop service"
docker compose stop $Service | Out-Null

Write-Host "==> Clean host logs"
Remove-Item -Force -ErrorAction SilentlyContinue .\logs\fintech\danipa-fintech-service.log
Remove-Item -Force -ErrorAction SilentlyContinue .\logs\fintech\danipa-fintech-service.*.log

Write-Host "==> Clean container logs"
docker compose run --rm $Service sh -lc "rm -f /app/logs/danipa-fintech-service/* || true" | Out-Null

Write-Host "==> Start dependencies"
docker compose up -d config-server eureka-server kafka redis elasticsearch logstash danipa-vault postgres-dev

Write-Host "==> Start service"
docker compose up -d $Service

Write-Host "==> Wait & health"
Start-Sleep -Seconds 8
Invoke-RestMethod http://localhost:8080/ms/actuator/health | ConvertTo-Json -Depth 5

Write-Host "==> Flyway"
Invoke-RestMethod http://localhost:8080/ms/actuator/flyway | ConvertTo-Json -Depth 5
