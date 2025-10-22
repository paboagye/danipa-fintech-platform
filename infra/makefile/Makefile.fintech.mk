# ---- Makefile.fintech.mk ----
ifndef FINTECH_MK_LOADED
FINTECH_MK_LOADED := 1

##@ Fintech Service (compose exec)

# Compose service keys (NOT container_name). Override via: make ... FIN_SERVICE=<svc>
FIN_AGENT_CONT ?= fintech-agent
FIN_SERVICE    ?= fintech-service

# Strip CRLF & whitespace (Windows/WSL safety)
CR := $(shell printf '\r')
FIN_SERVICE := $(strip $(subst $(CR),,$(FIN_SERVICE)))

# Health URL reachable from docker network; host users should hit the domain instead
FINTECH_URL ?= http://$(FIN_SERVICE):8080

# Log patterns that indicate the agent is ready
FIN_AGENT_READY_PAT := authentication\ successful|token\ written|template\ server\ received\ new\ token|rendered

# External (Traefik) URLs for actuator helpers
ACT_BASE ?= https://fintech.local.danipa.com
ACT_URL  := $(ACT_BASE)/ms/actuator
ACT_USER ?= act
ACT_PASS ?= act-pass

# Wrapper for external actuator curl (declared in core, but guard if core not included)
ifndef ACT_CURL
  ACT_CURL = curl -sS -u $(ACT_USER):$(ACT_PASS)
endif

.PHONY: fintech-agent-up fintech-service-up fintech-up fintech-service-logs \
        fintech-refresh fintech-busrefresh fintech-show-prop \
        fintech-act-health fintech-act-info fintech-act-env fintech-act-env-key \
        fintech-act-metrics fintech-act-metric fintech-act-mappings \
        fintech-act-beans fintech-act-configprops fintech-act-refresh fintech-act-busrefresh \
        fintech-env-check fintech-config-check

fintech-agent-up: ## Start fintech Vault Agent and wait until it's authenticated/rendered
	@echo "-> Starting $(FIN_AGENT_CONT) ..."
	@docker compose --profile dev up -d $(FIN_AGENT_CONT)
	@echo "-> Waiting for $(FIN_AGENT_CONT) to authenticate & render ..."
	@bash -lc '\
	  for i in $$(seq 1 60); do \
	    LOGS="$$(docker logs --tail=200 $(FIN_AGENT_CONT) 2>&1)"; \
	    if echo "$$LOGS" | grep -qiE "$(FIN_AGENT_READY_PAT)"; then \
	      echo "   ✓ $(FIN_AGENT_CONT) is authenticated/rendered"; exit 0; \
	    fi; \
	    sleep 1; \
	  done; \
	  echo "ERROR: $(FIN_AGENT_CONT) did not finish auth/render in time" >&2; exit 1 \
	'

fintech-service-up: ## Start $(FIN_SERVICE) and wait for health via Docker network
	@echo "-> Starting $(FIN_SERVICE) ..."
	@docker compose --profile dev up -d $(FIN_SERVICE)
	$(call wait_http,$(FINTECH_URL))

fintech-up: fintech-agent-up fintech-service-up ## Start agent first, then service

fintech-service-logs: ## Tail service logs
	@docker compose logs -f $(FIN_SERVICE)

##@ Fintech Service (build)

.PHONY: build-fintech
build-fintech: ## Build fintech-service image with its own git metadata
	$(call build_with_git,danipa-fintech-service,fintech-service)

.PHONY: show-fintech-git
show-fintech-git: ## Show git info detected for fintech-service
	$(call show_git,danipa-fintech-service)

# Show a property pulled from /env inside the container
LOGGER ?= com.danipa.fintech
PROP   ?= logging.level.com.danipa.fintech

##@ Fintech Service (Actuator inside container)

fintech-show-prop: ## Show PROP from /ms/actuator/env inside container
	@svcs="$$( docker compose config --services )"; \
	svc="$$( printf '%s' '$(FIN_SERVICE)' | tr -d '\r' )"; \
	echo ">> FIN_SERVICE='$$svc'"; \
	[ -n "$$( docker compose ps -q $$svc )" ] || { echo "ERROR: $$svc not running"; exit 3; }; \
	curl -sS -u $(ACT_USER):$(ACT_PASS) http://localhost:8080/ms/actuator/env | \
	jq -r '.propertySources[] | select(.name|test("(applicationConfig|configserver):.*")) \
	       | .properties["$(PROP)"].value // empty' | \
	awk 'NF{print; found=1} END{if(!found) print "NOT FOUND"}' | sed 's/^/$(PROP)=/'


# ===== External actuator helpers (via gateway/Traefik) =====
fintech-act-health:      ## GET /ms/actuator/health
	@$(ACT_CURL) $(ACT_URL)/health | $(JQ)

fintech-act-info:        ## GET /ms/actuator/info
	@$(ACT_CURL) $(ACT_URL)/info | $(JQ)

fintech-act-env:         ## GET /ms/actuator/env
	@$(ACT_CURL) $(ACT_URL)/env | $(JQ)

fintech-act-env-key:     ## GET /ms/actuator/env/{KEY} (KEY=spring.profiles.active)
	@test -n "$(KEY)" || { echo "Usage: make fintech-act-env-key KEY=<property.key>"; exit 2; }
	@$(ACT_CURL) $(ACT_URL)/env/$(KEY) | $(JQ)

fintech-act-metrics:     ## List metrics
	@$(ACT_CURL) $(ACT_URL)/metrics | $(JQ)

fintech-act-metric:      ## GET /ms/actuator/metrics/{NAME} [Q='?tag=k:v&tag=k2:v2']
	@test -n "$(NAME)" || { echo "Usage: make fintech-act-metric NAME=<metric.name> [Q=?tag=k:v]"; exit 2; }
	@$(ACT_CURL) "$(ACT_URL)/metrics/$(NAME)$(Q)" | $(JQ)

fintech-act-mappings:    ## GET /ms/actuator/mappings
	@$(ACT_CURL) $(ACT_URL)/mappings | $(JQ)

fintech-act-beans:       ## GET /ms/actuator/beans
	@$(ACT_CURL) $(ACT_URL)/beans | $(JQ)

fintech-act-configprops: ## GET /ms/actuator/configprops
	@$(ACT_CURL) $(ACT_URL)/configprops | $(JQ)

fintech-act-refresh:     ## POST /ms/actuator/refresh (external)
	@$(ACT_CURL) -X POST $(ACT_URL)/refresh -i

fintech-act-busrefresh:  ## POST /ms/actuator/busrefresh (external fan-out)
	@$(ACT_CURL) -X POST $(ACT_URL)/busrefresh -i

##@ Fintech Service (Actuator (inside container, HTTP)

fintech-refresh: ## POST /ms/actuator/refresh inside the running service container
	@svcs="$$( docker compose config --services )"; \
	svc="$$( printf '%s' '$(FIN_SERVICE)' | tr -d '\r' )"; \
	echo ">> FIN_SERVICE='$$svc'"; \
	echo "$$svcs" | grep -qx "$$svc" || { \
	  echo "ERROR: service '$$svc' not found."; \
	  echo "Detected services:"; echo "$$svcs" | sed 's/^/  - /'; \
	  echo ""; echo "Hint: make fintech-refresh FIN_SERVICE=<one-of-the-above>"; exit 2; \
	}; \
	cid="$$( docker compose ps -q $$svc )"; \
	[ -n "$$cid" ] || { echo "ERROR: '$$svc' is not running. Start it with: make fintech-service-up FIN_SERVICE=$$svc"; exit 3; }; \
	docker compose exec $$svc \
	  sh -lc 'curl -sS -i -u $(ACT_USER):$(ACT_PASS) -X POST http://localhost:8080/ms/actuator/refresh || exit $$?'

fintech-busrefresh: ## POST /ms/actuator/busrefresh inside the running service container (fan-out)
	@svcs="$$( docker compose config --services )"; \
	svc="$$( printf '%s' '$(FIN_SERVICE)' | tr -d '\r' )"; \
	echo ">> FIN_SERVICE='$$svc'"; \
	echo "$$svcs" | grep -qx "$$svc" || { \
	  echo "ERROR: service '$$svc' not found."; \
	  echo "Detected services:"; echo "$$svcs" | sed 's/^/  - /'; \
	  echo ""; echo "Hint: make fintech-busrefresh FIN_SERVICE=<one-of-the-above>"; exit 2; \
	}; \
	cid="$$( docker compose ps -q $$svc )"; \
	[ -n "$$cid" ] || { echo "ERROR: '$$svc' is not running. Start it with: make fintech-service-up FIN_SERVICE=$$svc"; exit 3; }; \
	docker compose exec $$svc \
	  sh -lc 'curl -sS -i -u $(ACT_USER):$(ACT_PASS) -X POST http://localhost:8080/ms/actuator/busrefresh || exit $$?'

##@ Fintech Service (Troubleshooting)
fintech-env-check: ## Check Spring-related env vars (SPRING_DATASOURCE, SPRING_CLOUD_CONFIG, SPRING_PROFILES, SPRING_CONFIG_IMPORT) inside running fintech-service container
	@docker compose exec -T fintech-service bash -lc \
	  'env | egrep -i "SPRING_(DATASOURCE|CLOUD_CONFIG|PROFILES|CONFIG_IMPORT)" || true'

fintech-config-check:
	@docker compose exec -T fintech-service sh -lc '\
	  set -eu; \
	  echo "[env]"; env | sort | egrep -i "^SPRING_(DATASOURCE|CLOUD_CONFIG|PROFILES|CONFIG_IMPORT)" || true; \
	  echo "[actuator]"; \
	  curl -fsS localhost:8080/ms/actuator/env >/tmp/env.json || { echo "actuator/env not reachable"; exit 1; }; \
	  grep -oE "\"spring.datasource.url\"[^}]*\"value\"\\s*:\\s*\"[^\"]+\"" /tmp/env.json || echo "no spring.datasource.url in actuator/env"'

endif
