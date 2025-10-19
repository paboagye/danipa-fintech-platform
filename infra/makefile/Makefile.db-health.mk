# --- Compose command & defaults
COMPOSE ?= docker compose

# Service key (compose) and container name (runtime). Adjust if you change compose.
PG_SVC       ?= postgres-dev           # compose service key
PG_CONT_NAME ?= danipa-postgres-dev    # container_name from compose
AGENT_SVC    ?= postgres-agent

# If your services use profiles, set them here (or override: make ... COMPOSE_PROFILES=dev,foo)
COMPOSE_PROFILES ?= dev

# Normalize any accidental whitespace from Windows/WSL edits
PG_SVC        := $(strip $(PG_SVC))
PG_CONT_NAME  := $(strip $(PG_CONT_NAME))

DB_HEALTH_SCRIPT ?= /vault/scripts/db-bootstrap-check.sh

db-health: ## Bring up agent+postgres and run the health check inside the DB container
	@echo '👉 Ensuring $(AGENT_SVC) is up...'
	$(COMPOSE) --profile $(COMPOSE_PROFILES) up -d $(AGENT_SVC)

	@echo '👉 Ensuring $(PG_SVC) (postgres) is up...'
	@if $(COMPOSE) config --services | grep -qx '$(PG_SVC)'; then \
	  $(COMPOSE) --profile $(COMPOSE_PROFILES) up -d $(PG_SVC); \
	else \
	  echo "⚠️  Compose service '$(PG_SVC)' not found. Skipping compose up."; \
	fi

	@echo '🔎 Resolving a running container to exec into...'
	@cid="$$( $(COMPOSE) --profile $(COMPOSE_PROFILES) ps -q $(PG_SVC) 2>/dev/null || true )"; \
	if [ -z "$$cid" ]; then \
	  cid="$$( docker ps -q --filter 'name=$(PG_CONT_NAME)$$' )"; \
	fi; \
	if [ -z "$$cid" ]; then \
	  echo "❌ No running container found for service '$(PG_SVC)' or name '$(PG_CONT_NAME)'"; \
	  echo "   Hints:"; \
	  echo "     - Start via:  docker compose --profile $(COMPOSE_PROFILES) up -d $(PG_SVC)"; \
	  echo "     - Or override: make db-health PG_SVC=<service-key>  or  PG_CONT_NAME=<container-name>"; \
	  exit 2; \
	fi; \
	echo "🩺 Running health check in container $$cid ..."; \
	docker exec -it $$cid sh -lc '$(DB_HEALTH_SCRIPT)'

# Convenience aliases
db-health-dev: PG_SVC=postgres-dev
db-health-dev: PG_CONT_NAME=danipa-postgres-dev
db-health-dev: COMPOSE_PROFILES=dev
db-health-dev: db-health

db-health-prod: PG_SVC=postgres-prod
db-health-prod: PG_CONT_NAME=danipa-postgres-prod
db-health-prod: COMPOSE_PROFILES=prod
db-health-prod: db-health
