# --- infra/makefile/Makefile.config.mk ---

##@ Config Server (compose exec)

COMPOSE        ?= docker compose
CONFIG_SERVICE ?= config-server
CONFIG_SERVICE := $(strip $(subst $(CR),,$(CONFIG_SERVICE)))

CONFIG_PORT    ?= 8088

# INTERNAL: Config Server listens with TLS on 8088 inside the container.
CONFIG_INT_SCHEME ?= https
CONFIG_INT_URL    ?= $(CONFIG_INT_SCHEME)://localhost:$(CONFIG_PORT)
# Use the container-mounted CA for verification (mounted by your compose)
CONFIG_INT_CACERT ?= /opt/tls/root_ca.crt

# EXTERNAL: Traefik terminates TLS; default to HTTPS.
CONFIG_EXT_SCHEME ?= https
CONFIG_HOST       ?= $(CONFIG_SERVICE)
CONFIG_URL        ?= $(CONFIG_EXT_SCHEME)://$(CONFIG_HOST):$(CONFIG_PORT)

# Build per-target curl flags (reuse shared flags and append CA for internal)
INT_FLAGS = $(CURL_INT_FLAGS) --cacert "$(CONFIG_INT_CACERT)"

.PHONY: config-service-up
config-service-up: ## Start config-server and wait for health (external URL)
	@echo "-> Starting $(CONFIG_SERVICE) ..."
	@$(COMPOSE) up -d $(CONFIG_SERVICE)
	$(call wait_http,$(CONFIG_URL))

.PHONY: config-service-logs
config-service-logs: ## Tail config-server logs
	@$(COMPOSE) logs -f $(CONFIG_SERVICE)

.PHONY: config-bash
config-bash: ## Shell into config-server container
	@$(COMPOSE) exec $(CONFIG_SERVICE) bash

##@ Config Server (build)

.PHONY: build-config
build-config: ## Build config-server image with its own git metadata
	$(call build_with_git,danipa-config-server,config-server)

.PHONY: show-config-git
show-config-git: ## Show git info detected for config-server
	$(call show_git,danipa-config-server)

##@ Config Server (Actuator (inside container, HTTPS + CA)
# ---- Actuator (inside container, HTTPS + CA) ----
.PHONY: config-act-health
config-act-health: ## GET $(CONFIG_INT_URL)/actuator/health (inside)
	@$(COMPOSE) exec $(CONFIG_SERVICE) sh -lc '\
	  resp=$$(curl -sS $(INT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(CONFIG_INT_URL)/actuator/health" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: config-act-info
config-act-info: ## GET $(CONFIG_INT_URL)/actuator/info (inside)
	@$(COMPOSE) exec $(CONFIG_SERVICE) sh -lc '\
	  resp=$$(curl -sS $(INT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(CONFIG_INT_URL)/actuator/info" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: config-act-env
config-act-env: ## GET $(CONFIG_INT_URL)/actuator/env (inside)
	@$(COMPOSE) exec $(CONFIG_SERVICE) sh -lc '\
	  resp=$$(curl -sS $(INT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(CONFIG_INT_URL)/actuator/env" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: config-act-metrics
config-act-metrics: ## GET $(CONFIG_INT_URL)/actuator/metrics (inside)
	@$(COMPOSE) exec $(CONFIG_SERVICE) sh -lc '\
	  resp=$$(curl -sS $(INT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(CONFIG_INT_URL)/actuator/metrics" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: config-refresh
config-refresh: ## POST $(CONFIG_INT_URL)/actuator/refresh (inside)
	@$(COMPOSE) exec $(CONFIG_SERVICE) sh -lc '\
	  curl -sS -i $(INT_FLAGS) -u $(ACT_USER):$(ACT_PASS) -X POST "$(CONFIG_INT_URL)/actuator/refresh" || true'

.PHONY: config-busrefresh
config-busrefresh: ## POST $(CONFIG_INT_URL)/actuator/busrefresh (inside)
	@$(COMPOSE) exec $(CONFIG_SERVICE) sh -lc '\
	  curl -sS -i $(INT_FLAGS) -u $(ACT_USER):$(ACT_PASS) -X POST "$(CONFIG_INT_URL)/actuator/busrefresh" || true'

##@ Config Server (external)

# You probably want to hit Traefik domain from the host:
#   make config-ext-info CONFIG_ACT_EXT_BASE=https://config.local.danipa.com USE_CUSTOM_CA=1 CA_CERT=infra/step/root_ca.crt
CONFIG_ACT_EXT_BASE ?= $(CONFIG_URL)

# Allow overriding the external CA path explicitly when USE_CUSTOM_CA=1
CA_CERT ?= infra/step/root_ca.crt
ifeq ($(USE_CUSTOM_CA),1)
  CURL_EXT_FLAGS += --cacert "$(CA_CERT)"
endif

.PHONY: config-ext-health
config-ext-health: ## GET $(CONFIG_ACT_EXT_BASE)/actuator/health (external)
	@sh -lc '\
	  resp=$$(curl -sS $(CURL_EXT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(CONFIG_ACT_EXT_BASE)/actuator/health" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: config-ext-info
config-ext-info: ## GET $(CONFIG_ACT_EXT_BASE)/actuator/info (external)
	@sh -lc '\
	  resp=$$(curl -sS $(CURL_EXT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(CONFIG_ACT_EXT_BASE)/actuator/info" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: config-ext-env
config-ext-env: ## GET $(CONFIG_ACT_EXT_BASE)/actuator/env (external)
	@sh -lc '\
	  resp=$$(curl -sS $(CURL_EXT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$(CONFIG_ACT_EXT_BASE)/actuator/env" || true); \
	  if command -v jq >/dev/null 2>&1; then printf "%s" "$$resp" | jq -Rr '\''fromjson? // .'\''; else printf "%s\n" "$$resp"; fi'

.PHONY: config-ext-refresh
config-ext-refresh: ## POST $(CONFIG_ACT_EXT_BASE)/actuator/refresh (external)
	@sh -lc '\
	  curl -sS -i $(CURL_EXT_FLAGS) -u $(ACT_USER):$(ACT_PASS) -X POST "$(CONFIG_ACT_EXT_BASE)/actuator/refresh" || true'

.PHONY: config-ext-busrefresh
config-ext-busrefresh: ## POST $(CONFIG_ACT_EXT_BASE)/actuator/busrefresh (external)
	@sh -lc '\
	  curl -sS -i $(CURL_EXT_FLAGS) -u $(ACT_USER):$(ACT_PASS) -X POST "$(CONFIG_ACT_EXT_BASE)/actuator/busrefresh" || true'
