$pair   = "CHANGE_ME:CHANGE_ME"
$basic  = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))

# default (Git only)
Invoke-RestMethod -Headers @{Authorization=$basic} -Uri "http://localhost:8088/danipa-fintech-service/default"

# dev (Git + Vault overlay via X-Config-Token) – optional once Git 200 works
# ($hvs is the Vault token you already know how to fetch via AppRole)
Invoke-RestMethod -Headers @{Authorization=$basic; "X-Config-Token"=$hvs} -Uri "http://localhost:8088/danipa-fintech-service/dev"

# enable TRACE for the config server & JGit at runtime
$auth=@{Authorization=$basic}
Invoke-RestMethod -Method POST -Headers $auth -ContentType 'application/json' `
  -Uri 'http://localhost:8088/actuator/loggers/org.springframework.cloud.config.server' `
  -Body '{ "configuredLevel": "TRACE" }'

Invoke-RestMethod -Method POST -Headers $auth -ContentType 'application/json' `
  -Uri 'http://localhost:8088/actuator/loggers/org.eclipse.jgit' `
  -Body '{ "configuredLevel": "TRACE" }'

# now tail the logs
docker logs -f --since=5m danipa-config-server