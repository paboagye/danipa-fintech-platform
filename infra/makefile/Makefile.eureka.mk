# --- infra/makefile/Makefile.eureka.mk ---

##@ Eureka Server (compose exec)

COMPOSE        ?= docker compose
EUREKA_SERVICE ?= eureka-server
EUREKA_SERVICE := $(strip $(subst $(CR),,$(EUREKA_SERVICE)))

EUREKA_PORT    ?= 8761

# Internal (container → localhost). Default HTTP; override with EUREKA_INT_SCHEME=https if TLS terminates in the app.
EUREKA_INT_SCHEME ?= http
EUREKA_INT_URL    ?= $(EUREKA_INT_SCHEME)://localhost:$(EUREKA_PORT)

# External (host/Traefik). Default HTTPS.
EUREKA_EXT_SCHEME ?= https
EUREKA_HOST       ?= $(EUREKA_SERVICE)
EUREKA_URL        ?= $(EUREKA_EXT_SCHEME)://$(EUREKA_HOST):$(EUREKA_PORT)

.PHONY: eureka-service-up
eureka-service-up: ## Start eureka-server and wait for health (external URL)
	@echo "-> Starting $(EUREKA_SERVICE) ..."
	@$(COMPOSE) up -d $(EUREKA_SERVICE)
	$(call wait_http,$(EUREKA_URL))

.PHONY: eureka-service-logs
eureka-service-logs: ## Tail eureka-server logs
	@$(COMPOSE) logs -f $(EUREKA_SERVICE)

.PHONY: eureka-bash
eureka-bash: ## Shell into eureka-server container
	@$(COMPOSE) exec $(EUREKA_SERVICE) bash

##@ Eureka Server (build)

.PHONY: build-eureka
build-eureka: ## Build eureka-server image with its own git metadata
	$(call build_with_git,danipa-eureka-server,eureka-server)

.PHONY: show-eureka-git
show-eureka-git: ## Show git info detected for eureka-server
	$(call show_git,danipa-eureka-server)

##@ Eureka Server (Actuator inside)
# ---- Actuator (inside container) ----
.PHONY: eureka-act-health
eureka-act-health: ## GET $(EUREKA_INT_URL)/actuator/health (inside)
	@$(COMPOSE) exec $(EUREKA_SERVICE) sh -lc '\
	  resp=$$(curl -sS $(CURL_INT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(EUREKA_INT_URL)/actuator/health" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: eureka-act-info
eureka-act-info: ## GET $(EUREKA_INT_URL)/actuator/info (inside)
	@$(COMPOSE) exec $(EUREKA_SERVICE) sh -lc '\
	  resp=$$(curl -sS $(CURL_INT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(EUREKA_INT_URL)/actuator/info" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: eureka-act-env
eureka-act-env: ## GET $(EUREKA_INT_URL)/actuator/env (inside)
	@$(COMPOSE) exec $(EUREKA_SERVICE) sh -lc '\
	  resp=$$(curl -sS $(CURL_INT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(EUREKA_INT_URL)/actuator/env" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: eureka-act-metrics
eureka-act-metrics: ## GET $(EUREKA_INT_URL)/actuator/metrics (inside)
	@$(COMPOSE) exec $(EUREKA_SERVICE) sh -lc '\
	  resp=$$(curl -sS $(CURL_INT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(EUREKA_INT_URL)/actuator/metrics" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

##@ Eureka Server (Actuator external)

EUREKA_ACT_EXT_BASE ?= $(EUREKA_URL)

.PHONY: eureka-ext-health
eureka-ext-health: ## GET $(EUREKA_ACT_EXT_BASE)/actuator/health (external)
	@sh -lc '\
	  resp=$$(curl -sS $(CURL_EXT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(EUREKA_ACT_EXT_BASE)/actuator/health" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: eureka-ext-info
eureka-ext-info: ## GET $(EUREKA_ACT_EXT_BASE)/actuator/info (external)
	@sh -lc '\
	  resp=$$(curl -sS $(CURL_EXT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(EUREKA_ACT_EXT_BASE)/actuator/info" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: eureka-ext-env
eureka-ext-env: ## GET $(EUREKA_ACT_EXT_BASE)/actuator/env (external)
	@sh -lc '\
	  resp=$$(curl -sS $(CURL_EXT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(EUREKA_ACT_EXT_BASE)/actuator/env" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'
