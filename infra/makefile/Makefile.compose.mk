# ---- Makefile.compose.mk ----
ifndef COMPOSE_MK_LOADED
COMPOSE_MK_LOADED := 1

##@ Docker / Compose
.PHONY: network up up-core down ps logs bash restart compose-config clean-volumes prune

VAULT_SERVICE ?= vault

network: ## Create external docker network (idempotent)
	$(call hdr,Create network $(NET))
	@docker network create $(NET) 2>/dev/null || true
	@docker network ls | grep -E '\b$(NET)\b' || (echo "!! Network not found" && exit 1)

up: network ## Bring up all services (detached)
	$(call hdr,Compose UP)
	$(COMPOSE) up -d

up-core: network ## Bring up core stack
	$(call hdr,Compose UP core)
	$(COMPOSE) up -d vault keycloak config-server eureka-server fintech-service postgres-dev redis kafka

down: ## Stop and remove containers
	$(call hdr,Compose DOWN)
	$(COMPOSE) down

ps: ## Show compose services
	$(COMPOSE) ps

logs: ## Tail logs: make logs SERVICE=fintech-service
	@test -n "$(SERVICE)" || (echo "Usage: make logs SERVICE=<name>"; exit 1)
	$(COMPOSE) logs -f $(SERVICE)

bash: ## Shell into a running container: make bash SERVICE=fintech-service
	@test -n "$(SERVICE)" || (echo "Usage: make bash SERVICE=<name>"; exit 1)
	@$(COMPOSE) exec $(SERVICE) bash

restart: ## Restart service: make restart SERVICE=fintech-service
	@test -n "$(SERVICE)" || (echo "Usage: make restart SERVICE=<name>"; exit 1)
	$(COMPOSE) up -d --no-deps --force-recreate $(SERVICE)

compose-config: ## Print merged compose file config (debug)
	$(COMPOSE) config

clean-volumes: ## Remove containers + anonymous volumes
	$(COMPOSE) down -v

prune: ## Prune dangling images, networks, volumes (DANGEROUS)
	@docker system prune -f
	@docker volume prune -f
	@docker network prune -f

endif
