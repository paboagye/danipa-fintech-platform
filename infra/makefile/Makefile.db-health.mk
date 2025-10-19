.PHONY: db-health db-health-dev db-health-prod

# Default container names (override with `make db-health PG_SVC=...`)
PG_SVC ?= danipa-postgres-dev
DB_HEALTH_SCRIPT ?= /vault/scripts/db-bootstrap-check.sh

# Bring up the service (and dependencies) and run the in-container health script
db-health:
\t@echo '👉 Ensuring $(PG_SVC) is up...'
\tdocker compose up -d postgres-dev
\t@echo '🩺 Running health check inside $(PG_SVC)...'
\tdocker exec -it $(PG_SVC) sh -lc '$(DB_HEALTH_SCRIPT)'

# Convenience aliases if you keep multiple envs
db-health-dev: PG_SVC=danipa-postgres-dev
db-health-dev: db-health

db-health-prod: PG_SVC=danipa-postgres-prod
db-health-prod: db-health
