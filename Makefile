# ===============================
# Danipa Fintech Platform - Makefile
# Unified Application & Vault Management (compose-friendly vault certs)
# ===============================
SHELL := /bin/bash
.DEFAULT_GOAL := help
.ONESHELL:

ifneq (,$(wildcard .env))
include .env
export
endif

# ---------- Compose / Network ----------
COMPOSE ?= docker compose
NET     ?= danipa-net
VAULT_SERVICE ?= vault            # compose service name (matches your original flow)

# ---------- Core URLs ----------
VAULT_ADDR        ?= https://vault.local.danipa.com
CONFIG_URL        ?= http://config-server:8088
EUREKA_URL        ?= http://eureka-server:8761
FINTECH_URL       ?= http://fintech-service:8080
KEYCLOAK_URL      ?= http://keycloak:8080

# ---------- TLS / Files ----------
VAULT_HOST_HTTPS  ?= https://vault.local.danipa.com:18300
VAULT_CACERT      ?= infra/vault/tls/root_ca.crt
TLS_DIR           ?= infra/vault/tls
VAULT_EXT         ?= https://vault.local.danipa.com

# Force DNS so curl hits 127.0.0.1 while keeping SNI/host verification.
# (write-secrets.sh will honor this and pass it to curl as --resolve)
VAULT_FORCE_RESOLVE ?= vault.local.danipa.com:443:127.0.0.1

# -------------------------------------------------------------------
# Existing vars (yours)
VAULT_CONT         ?= danipa-vault
AGENT_CONT         ?= postgres-agent
PG_CONT            ?= danipa-postgres-dev
DANIPA_NET         ?= danipa-net

VAULT_ADDR         ?= https://127.0.0.1:8200
VAULT_CACERT       ?= /vault/tls/root_ca.crt
APPROLE_NAME       ?= fintech-role-dev
KV_PATH_DATA       ?= secret/data/danipa/fintech/dev
KV_PATH_HUMAN      ?= secret/danipa/fintech/dev
VAULT_POLICY_NAME  ?= pg-read

# ---- Backups ----------------------------------------------------------------
BACKUP_DIR ?= backups/db
# Optional override: make pg-dump DB=my_other_db
DB ?= $(DB_NAME)

# ---------- Secrets / Scripts ----------
SEEDS_DIR         ?= infra/vault/seeds
SCRIPTS_DIR       ?= infra/vault/scripts
WRITE_SECRETS     ?= $(SCRIPTS_DIR)/write-secrets.sh
DEV_JSON          ?= dev.json
UNSEAL_KEY_FILE   ?= infra/vault/keys/vault-unseal.key

# ===== DB permission probe =====
POSTGRES_CONTAINER ?= danipa-postgres-dev
DB_USER            ?= danipa_owner_dev
DB_NAME            ?= danipa_fintech_db_dev

# pgAdmin vars
PGADMIN_GROUP ?= Danipa
PG_NAME       ?= Postgres-Dev
PG_HOST       ?= $(PG_CONT)
PG_PORT       ?= 5432
FORCE_PGADMIN_REIMPORT ?= 0

APP_ENV ?= dev
#PGHOST ?= localhost
#PGPORT ?= 55432
PGUSER ?= postgres
PGPASSWORD ?= postgres

OWNER_ROLE         ?= danipa_owner_dev
APP_ROLE           ?= danipa_app_dev
RO_ROLE            ?= danipa_ro_dev
MIGRATOR_ROLE      ?= danipa_migrator_dev

APP_SCHEMAS        ?= fintech core payments momo webhooks audit ops

# ---- Fintech agent & service -------------------------------------------------
FIN_AGENT_CONT ?= fintech-agent
# Pick the Compose service key (NOT container_name). Override via: make ... FIN_SERVICE=<svc>
FIN_SERVICE     ?= fintech-service

# Strip CRLF and surrounding whitespace (Windows/WSL safety)
CR := $(shell printf '\r')
FIN_SERVICE := $(strip $(subst $(CR),,$(FIN_SERVICE)))

# Build health URL from the service key (reachable from the docker network; for host use your domain)
FINTECH_URL ?= http://$(FIN_SERVICE):8080

# A couple of log patterns that indicate the agent is ready
FIN_AGENT_READY_PAT := 'authentication successful\|token written\|template server received new token\|rendered '

# ELK Makefile — snapshot/restore & health automation (9.1.x)
# Usage:
#   ES_URL?=http://localhost:9200 make es-health
#   ES_URL=https://elasticsearch:9200 ES_INSECURE=1 ES_API_KEY=... make es-snapshot-create
#   SNAPSHOT_REPO=danipa-backups make es-restore-latest
#
# Auth precedence: ES_API_KEY > (ES_USER + ES_PASSWORD) > none

SHELL := /bin/bash

# -------- ELK/Logstash --------
ES_URL        ?= http://localhost:9200
KIBANA_URL    ?= http://localhost:5601
LOGSTASH_URL  ?= http://logstash:9600

# Add missing defaults used by snapshot targets
WAIT_STATUS         ?= yellow
SNAPSHOT_REPO       ?= danipa-backups
ES_SNAPSHOT_FS_PATH ?= /usr/share/elasticsearch/snapshots
DATE                := $(shell date +%Y%m%d%H%M%S)
SNAP_NAME           ?= manual-$(DATE)

CURL_FLAGS := -fsS
ifdef ES_INSECURE
  CURL_FLAGS += -k
endif

ifdef ES_API_KEY
  AUTH_HDR := -H "Authorization: ApiKey $(ES_API_KEY)"
endif
ifdef ES_USER
  BASIC_AUTH := -u $(ES_USER):$(ES_PASSWORD)
endif

# --- Run curl either on host or in a tiny container attached to danipa-net ---
ifeq ($(USE_DOCKER_CURL),1)
  CURL_IMG ?= curlimages/curl:8.10.1
  curl_es = docker run --rm --network $(NET) $(CURL_IMG) $(CURL_FLAGS) $(AUTH_HDR) $(BASIC_AUTH)

  # When dockerized, prefer internal DNS if the user left defaults
  ifneq (,$(findstring localhost,$(ES_URL)))
    ES_URL := http://elasticsearch:9200
  endif
  ifneq (,$(findstring localhost,$(KIBANA_URL)))
    KIBANA_URL := http://kibana:5601
  endif
  ifneq (,$(findstring localhost,$(LOGSTASH_URL)))
    LOGSTASH_URL := http://logstash:9600
  endif
else
  curl_es = curl $(CURL_FLAGS) $(AUTH_HDR) $(BASIC_AUTH)
endif

# ---------- Env / Misc ----------
VAULT_TOKEN       ?= $(shell jq -r '.root_token // empty' infra/vault/keys/vault-keys.json 2>/dev/null)
CURL_SILENT       ?= -fsS --connect-timeout 3 --max-time 5

### === Scope verification helpers ===
# Usage:
#   make verify-scope CID=eureka-server SEC=xxxx
#   make verify-scope CID=eureka-server SEC=xxxx SCOPE=config.read
#   make verify-scope-all ENV=dev SCOPE=config.read   # loops callers, pulls secrets from seeds or env
#
# Requires: curl, jq, base64
# Uses: infra/vault/scripts/verify-scope.sh

REALM ?= danipa
KC    ?= http://localhost:8082
ENV   ?= dev
# IMPORTANT: expand SEEDS immediately so it doesn't carry a raw $(ENV) into sh -c strings
SEEDS := infra/vault/seeds/$(ENV).json
CALLERS ?= eureka-server danipa-fintech-service
SCRIPTS_DIR ?= infra/vault/scripts

# ==== Actuator vars & helpers (external URL) ====
ACT_BASE ?= https://fintech.local.danipa.com
ACT_URL  := $(ACT_BASE)/ms/actuator

ACT_USER ?= act
ACT_PASS ?= act-pass

# defaults (can override per-invocation)
LOGGER   ?= com.danipa.fintech
PROP     ?= logging.level.com.danipa.fintech

# jq pretty by default; set JQ='' to get raw
JQ ?= jq

# wrapper
ACT_CURL = curl -sS -u $(ACT_USER):$(ACT_PASS)

# SAN handling (defaults are added by the script itself)
CN          ?= vault.local.danipa.com
SANS        ?= vault.local.danipa.com vault localhost 127.0.0.1
EXTRA_SANS  ?=
SANS_FINAL  := $(SANS) $(EXTRA_SANS)

# Build a list of only the *extra* SANs to hand to the script
define FILTER_EXTRAS
  awk '{
    for (i=1;i<=NF;i++){
      s=$$i;
      if (s!="$(CN)" && s!="vault" && s!="localhost" && s!="127.0.0.1") print s
    }
  }' <<< "$(SANS_FINAL)" | xargs
endef
SCRIPT_SANS := $(shell $(FILTER_EXTRAS))

VAULT_CERT_SCRIPT ?= infra/vault/scripts/cert/vault_cert.sh
TLS_DIR           ?= infra/vault/tls
VAULT_SERVICE     ?= vault
VAULT_HOST_HTTPS  ?= https://$(CN):18300

# Curl retry policy for transient start-up errors (e.g., SSL_ERROR_SYSCALL while Vault binds 18300)
# ---- Health URL with friendlier status codes ----
# Adjust to your taste; this example returns 200 for most non-error states
HEALTH_URL := https://$(CN):18300/v1/sys/health?standbyok=true&perfstandbyok=true&sealedcode=200&uninitcode=200&drsecondarycode=200

# ---- Curl retry policy (curl 8.5.0 compatible) ----
CURL_RETRY_FLAGS := \
  --fail \
  --retry 60 \
  --retry-delay 1 \
  --retry-max-time 120 \
  --retry-all-errors \
  --retry-connrefused

# Optional: DEBUG=1 to see attempts/timing
CURL_DEBUG_FLAGS :=
ifdef DEBUG
CURL_DEBUG_FLAGS := -v --trace-time --write-out '\nhttp=%{http_code} connects=%{num_connects} total=%{time_total}s\n'
endif

# Reusable health check command
CURL_HEALTH = curl -sS --http1.1 $(CURL_RETRY_FLAGS) $(CURL_DEBUG_FLAGS) \
  --connect-timeout 2 \
  --cacert "$(TLS_DIR)/root_ca.crt" \
  --connect-to "$(CN)":18300:127.0.0.1:18300 \
  "$(HEALTH_URL)"

CERT_NOT_AFTER ?= 9528h  # ~13 months; safe for most clients

# ---------- Step CA (cert issuance) ----------
# The CA certificate’s DNS name must match this host (used for SNI).
STEP_CA_HOST ?= step-ca.local.danipa.com
# Compose service name that runs the CA:
STEP_CA_SVC  ?= step-ca
STEP_CA_PORT ?= 9000

PROV            ?= admin
PROV_PASS       ?=            # optional if you also provide PROV_PASS_FILE
PROV_PASS_FILE  ?=            # alternative to PROV_PASS: path to a local file with the password
VAULT_CERTS_DIR ?= /vault/config/certs

# Safety: strip any accidental whitespace from host/port
STEP_CA_HOST_STRIPPED := $(strip $(STEP_CA_HOST))
STEP_CA_PORT_STRIPPED := $(strip $(STEP_CA_PORT))

# ===========================
# Bootstrap Keycloak & Vault
# ===========================
BOOTSTRAP_SCRIPT ?= infra/vault/scripts/bootstrap-keycloak-and-vault.sh
# External (Traefik) URLs the bootstrap uses by default
KC_EXT_BASE ?= https://keycloak.local.danipa.com
# Optionally force DNS -> 127.0.0.1 to keep SNI/host validation but hit localhost
# (Traefik listens on 443; keep these if you’re not editing /etc/hosts)
CURL_FORCE_RESOLVE ?= keycloak.local.danipa.com:443:127.0.0.1;vault.local.danipa.com:443:127.0.0.1
# Bootstrap knobs (inherited by the script). Tweak per run if needed:
REALM          ?= danipa
ENV_NAME       ?= dev
MOUNT          ?= secret
SEEDS_DIR      ?= infra/vault/seeds
WRITE_SECRETS  ?= ./infra/vault/scripts/write-secrets.sh
KC_ADMIN_USER  ?= admin
KC_ADMIN_PASS  ?= admin
# If TOKEN is empty, the script will read infra/vault/keys/vault-keys.json
TOKEN          ?=

# Config server
CONFIG_CERT_SCRIPT ?= infra/config-server/scripts/cert/config_server_cert.sh
CONFIG_TLS_DIR     ?= infra/config-server/tls
CONFIG_CN          ?= config-server
CONFIG_SANS        ?= config.local.danipa.com

# ---------- Helpers ----------
define wait_http
@echo ">> Waiting for $(1) ..."
@i=0; \
until curl $(CURL_SILENT) -o /dev/null -w '%{http_code}\n' "$(1)/actuator/health" | \
  grep -Eq '^(2|3)'; do \
  i=$$((i+1)); if [ $$i -gt 60 ]; then echo "!! Timeout waiting for $(1)"; exit 1; fi; \
  sleep 2; \
done; \
echo "OK: $(1)"
endef

define hdr
@echo -e "\n=== $(1) ===\n"
endef

# ---------- Help ----------
.PHONY: help
help:
	@awk 'BEGIN {FS = ":.*##"; printf "\nDanipa Fintech Platform - Makefile\n\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	/^[a-zA-Z0-9_\-]+:.*##/ { printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0,5) } ' $(MAKEFILE_LIST)

##@ Docker / Compose
.PHONY: network
network: ## Create external docker network (idempotent)
	$(call hdr,Create network $(NET))
	@docker network create $(NET) 2>/dev/null || true
	@docker network ls | grep -E '\b$(NET)\b' || (echo "!! Network not found" && exit 1)

.PHONY: up
up: network ## Bring up all services (detached)
	$(call hdr,Compose UP)
	$(COMPOSE) up -d

.PHONY: up-core
up-core: network ## Bring up core stack
	$(call hdr,Compose UP core)
	$(COMPOSE) up -d vault keycloak config-server eureka-server fintech-service postgres-dev redis kafka

.PHONY: down
down: ## Stop and remove containers
	$(call hdr,Compose DOWN)
	$(COMPOSE) down

.PHONY: ps
ps: ## Show compose services
	$(COMPOSE) ps

.PHONY: logs
logs: ## Tail logs: make logs SERVICE=fintech-service
	@test -n "$(SERVICE)" || (echo "Usage: make logs SERVICE=<name>"; exit 1)
	$(COMPOSE) logs -f $(SERVICE)

.PHONY: bash
bash: ## Shell into a running container: make bash SERVICE=fintech-service
	@test -n "$(SERVICE)" || (echo "Usage: make bash SERVICE=<name>"; exit 1)
	@$(COMPOSE) exec $(SERVICE) bash

.PHONY: restart
restart: ## Restart service: make restart SERVICE=fintech-service
	@test -n "$(SERVICE)" || (echo "Usage: make restart SERVICE=<name>"; exit 1)
	$(COMPOSE) up -d --no-deps --force-recreate $(SERVICE)

.PHONY: compose-config
compose-config: ## Print merged compose file config (debug)
	$(COMPOSE) config

.PHONY: clean-volumes
clean-volumes: ## Remove containers + anonymous volumes
	$(COMPOSE) down -v

.PHONY: prune
prune: ## Prune dangling images, networks, volumes (DANGEROUS)
	@docker system prune -f
	@docker volume prune -f
	@docker network prune -f

##@ Environment
.PHONY: env
env: ## Print key environment variables
	@echo "APP_ENV=$(APP_ENV)"
	@echo "CONFIG_URL=$(CONFIG_URL)"
	@echo "EUREKA_URL=$(EUREKA_URL)"
	@echo "FINTECH_URL=$(FINTECH_URL)"
	@echo "VAULT_ADDR=$(VAULT_ADDR)"
	@echo "VAULT_TOKEN=$(if $(VAULT_TOKEN),[set],[missing])"
	@echo "JAVA_TOOL_OPTIONS=$(JAVA_TOOL_OPTIONS)"
	@echo "KAFKA=$(SPRING_KAFKA_BOOTSTRAP_SERVERS)"

##@ Health Checks
.PHONY: health
health: health-vault health-config health-eureka health-fintech ## Run all service health checks

.PHONY: health-vault
health-vault: ## Check Vault health (HTTP API)
	$(call hdr,Vault Health)
	@curl $(CURL_SILENT) "$(VAULT_ADDR)/v1/sys/health" | jq . || true

.PHONY: health-vault-https
health-vault-https: ## Check Vault health via local HTTPS with custom CA
	$(call hdr,Vault Health (HTTPS + custom CA))
	@curl $(CURL_SILENT) --cacert "$(VAULT_CACERT)" "$(VAULT_HOST_HTTPS)/v1/sys/health" | jq . || true

.PHONY: health-config
health-config: ## Spring Cloud Config health
	$(call hdr,Config Server Health)
	@curl $(CURL_SILENT) "$(CONFIG_URL)/actuator/health" | jq . || true

.PHONY: health-eureka
health-eureka: ## Eureka health
	$(call hdr,Eureka Health)
	@curl $(CURL_SILENT) "$(EUREKA_URL)/actuator/health" | jq . || true

.PHONY: health-fintech
health-fintech: ## Fintech service health
	$(call hdr,Fintech Service Health)
	@curl $(CURL_SILENT) "$(FINTECH_URL)/actuator/health" | jq . || true

##@ Waiters
.PHONY: wait-core
wait-core: ## Wait for core services to be healthy
	$(call wait_http,$(CONFIG_URL))
	$(call wait_http,$(EUREKA_URL))
	$(call wait_http,$(FINTECH_URL))

##@ Vault & Secrets
.PHONY: vault-token
vault-token: ## Print current VAULT_TOKEN source (does not echo token value)
	@echo "VAULT_TOKEN=$(if $(VAULT_TOKEN),[set],[missing])  (source: infra/vault/keys/vault-keys.json if present)"

.PHONY: secrets-dev
secrets-dev: ## Seed secrets for DEV using write-secrets.sh (reads dev.json)
	$(call hdr,Seeding DEV secrets to Vault)
	@test -x "$(WRITE_SECRETS)" || (echo "!! $(WRITE_SECRETS) not found or not executable"; exit 1)
	@test -f "$(DEV_JSON)" || (echo "!! $(DEV_JSON) not found"; exit 1)
	@test -n "$(VAULT_TOKEN)" || (echo "!! VAULT_TOKEN not set and not found at infra/vault/keys/vault-keys.json"; exit 1)
	TOKEN="$(VAULT_TOKEN)" ENVS=dev "$(WRITE_SECRETS)"

.PHONY: secrets-staging
secrets-staging: ## Seed secrets for STAGING (expects stg json if used by script)
	@test -x "$(WRITE_SECRETS)" || (echo "!! $(WRITE_SECRETS) not found or not executable"; exit 1)
	@test -n "$(VAULT_TOKEN)" || (echo "!! VAULT_TOKEN not set"; exit 1)
	TOKEN="$(VAULT_TOKEN)" ENVS=staging "$(WRITE_SECRETS)"

.PHONY: secrets-prod
secrets-prod: ## Seed secrets for PROD (CAUTION)
	@test -x "$(WRITE_SECRETS)" || (echo "!! $(WRITE_SECRETS) not found or not executable"; exit 1)
	@test -n "$(VAULT_TOKEN)" || (echo "!! VAULT_TOKEN not set"; exit 1)
	TOKEN="$(VAULT_TOKEN)" ENVS=prod "$(WRITE_SECRETS)"

.PHONY: secrets-verify
secrets-verify: ## Dry-run: verify Vault writes without changing data
	@test -x "$(WRITE_SECRETS)" || (echo "!! $(WRITE_SECRETS) not found or not executable"; exit 1)
	@test -n "$(VAULT_TOKEN)" || (echo "!! VAULT_TOKEN not set"; exit 1)
	TOKEN="$(VAULT_TOKEN)" VERIFY_ONLY=true ENVS=dev,staging,prod "$(WRITE_SECRETS)"

.PHONY: kv-list
kv-list: ## List top-level KV v2 paths
	@test -n "$(VAULT_TOKEN)" || (echo "!! VAULT_TOKEN not set"; exit 1)
	@curl $(CURL_SILENT) -H "X-Vault-Token: $(VAULT_TOKEN)" "$(VAULT_ADDR)/v1/secret/metadata?list=true" | jq . || true

.PHONY: vault-cert
vault-cert: ## Issue Vault TLS cert via working script, restart Vault, health-check
	@echo ">> Issuing Vault cert for CN=$(CN)"
	@echo ">> Extra SANs: $(SCRIPT_SANS)"
	@test -x "$(VAULT_CERT_SCRIPT)" || (echo "!! $(VAULT_CERT_SCRIPT) not found or not executable"; exit 1)
	SANS="$(SCRIPT_SANS)" "$(VAULT_CERT_SCRIPT)" issue "$(CN)"

	@# sanity / visibility
	@$(MAKE) -s vault-cert-verify

	@echo ">> Restarting Vault to pick up new host-mounted certs ..."
	docker compose up -d --no-deps --force-recreate $(VAULT_SERVICE)

	@echo ">> Checking Vault API health (TLS) with curl retries ..."
	@$(CURL_HEALTH) | jq .

.PHONY: vault-cert-dry-run
vault-cert-dry-run: ## Issue cert only using the working script (no restart)
	@echo ">> Dry-run issuance for CN=$(CN)"
	@echo ">> Extra SANs: $(SCRIPT_SANS)"
	@test -x "$(VAULT_CERT_SCRIPT)" || (echo "!! $(VAULT_CERT_SCRIPT) not found or not executable"; exit 1)
	SANS="$(SCRIPT_SANS)" "$(VAULT_CERT_SCRIPT)" issue "$(CN)"
	@$(MAKE) -s vault-cert-verify

.PHONY: vault-cert-verify
vault-cert-verify: ## Checks and displays details about the current Vault TLS certificate
	@openssl x509 -in "$(TLS_DIR)/server-fullchain.crt" -noout -subject -issuer -dates -ext subjectAltName || true

.PHONY: vault-status
vault-status: ## Show Vault seal status (ignoring TLS verification)
	@echo ">> Checking Vault status (sealed/unsealed)..."
	docker compose exec -T $(VAULT_SERVICE) sh -lc 'vault status -address=https://127.0.0.1:8200 -tls-skip-verify || true'

.PHONY: vault-init
vault-init: ## Initialize Vault once (writes infra/vault/keys/* on the host)
	@echo ">> Initializing Vault (one-time) ..."
	@mkdir -p infra/vault/keys
	@docker compose exec -T $(VAULT_SERVICE) sh -lc '\
	  export VAULT_ADDR="https://127.0.0.1:8200" VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  vault operator init -format=json' \
	  > infra/vault/keys/vault-init.json
	@jq -r '.unseal_keys_b64[]' infra/vault/keys/vault-init.json > infra/vault/keys/unseal-keys.txt
	@jq -r '{root_token, unseal_keys_b64}' infra/vault/keys/vault-init.json > infra/vault/keys/vault-keys.json
	@head -n1 infra/vault/keys/unseal-keys.txt > infra/vault/keys/vault-unseal.key
	@chmod 0400 infra/vault/keys/vault-unseal.key infra/vault/keys/vault-keys.json
	@echo ">> Keys saved under infra/vault/keys/ (guard and back them up securely)"

.PHONY: vault-unseal
vault-unseal: ## Unseal Vault non-interactively (UNSEAL_KEY or infra/vault/keys/vault-unseal.key)
	@echo ">> Unsealing Vault (non-interactive)..."
	@KEY="$${UNSEAL_KEY:-$$(tr -d '\r\n ' < infra/vault/keys/vault-unseal.key 2>/dev/null)}"; \
	if [ -z "$$KEY" ]; then \
	  echo "ERROR: unseal key is empty. Set UNSEAL_KEY or put the key in infra/vault/keys/vault-unseal.key"; exit 1; \
	fi; \
	docker compose exec -T $(VAULT_SERVICE) sh -lc "vault operator unseal -address=https://127.0.0.1:8200 -tls-skip-verify $${KEY}"

.PHONY: vault-unseal-3
vault-unseal-3: ## Runs a loop to unseal HashiCorp Vault using the first three unseal keys from infra/vault/keys/unseal-keys.txt
	@sed -i 's/\r$$//' infra/vault/keys/unseal-keys.txt
	@for i in 1 2 3; do \
	  KEY="$$(sed -n "$${i}p" infra/vault/keys/unseal-keys.txt | tr -d '\r\n ')"; \
	  [ -n "$$KEY" ] || { echo "Missing key $$i"; exit 2; }; \
	  $(MAKE) --no-print-directory UNSEAL_KEY="$$KEY" vault-unseal; \
	done

.PHONY: vault-health
vault-health: ## Check Vault API health over TLS (with SNI + CA pinning)
	@echo ">> Checking Vault API health for CN=$(CN)..."
	curl -sS --cacert "$(TLS_DIR)/root_ca.crt" \
	  --resolve "$(CN)":18300:127.0.0.1 \
	  https://$(CN):18300/v1/sys/health | jq

# Use external TLS + custom CA + forced DNS pin for host-side seeding
VAULT_CACERT ?= infra/vault/tls/root_ca.crt
ENVS ?= dev

.PHONY: vault-seed
vault-seed: ## Seeds (writes) secrets into HashiCorp Vault for your environment
	@TOKEN=$$(jq -r '.root_token' infra/vault/keys/vault-keys.json); \
	test -n "$$TOKEN"; \
	test -x "$(WRITE_SECRETS)" || { echo "!! $(WRITE_SECRETS) not found or not executable"; exit 1; }; \
	VAULT_ADDR="$(VAULT_ADDR)" \
	VAULT_CACERT="$(VAULT_CACERT)" \
	VAULT_FORCE_RESOLVE="$(VAULT_FORCE_RESOLVE)" \
	ENVS="$(ENVS)" TOKEN="$$TOKEN" \
	bash "$(WRITE_SECRETS)"

.PHONY: vault-verify
vault-verify: ## Verifies that secrets can be read from Vault for the current environment without making any changes
	@TOKEN=$$(jq -r '.root_token' infra/vault/keys/vault-keys.json); \
	test -n "$$TOKEN"; \
	test -x "$(WRITE_SECRETS)" || { echo "!! $(WRITE_SECRETS) not found or not executable"; exit 1; }; \
	VAULT_ADDR="$(VAULT_ADDR)" \
	VAULT_CACERT="$(VAULT_CACERT)" \
	VAULT_FORCE_RESOLVE="$(VAULT_FORCE_RESOLVE)" \
	ENVS="$(ENVS)" TOKEN="$$TOKEN" VERIFY_ONLY=true \
	bash "$(WRITE_SECRETS)"


##@ Hosts helpers
HOSTS_SNIPPET ?= infra/hosts/hosts-snippet

.PHONY: hosts-snippet
hosts-snippet: ## Generate a hosts file snippet with Danipa domains (idempotent content)
	@mkdir -p infra/hosts
	@cat > $(HOSTS_SNIPPET) <<-'EOF'
	# Danipa Fintech Platform (local dev)
	127.0.0.1 vault.local.danipa.com keycloak.local.danipa.com \
	          config.local.danipa.com eureka.local.danipa.com \
	          fintech.local.danipa.com kibana.local.danipa.com \
	          pgadmin.local.danipa.com step-ca.local.danipa.com
	EOF
	@echo "Wrote $(HOSTS_SNIPPET)"

.PHONY: hosts-patch
hosts-patch: hosts-snippet ## Patch the system hosts file (Linux/mac: automatic; Windows: print instructions)
	@os=$$(uname -s || echo Unknown); \
	if [ "$$os" = "Darwin" ] || [ "$$os" = "Linux" ]; then \
	  echo ">> Detected $$os. Patching /etc/hosts (sudo may prompt)..."; \
	  if ! grep -q "vault.local.danipa.com" /etc/hosts 2>/dev/null; then \
	    sudo sh -c 'printf "\\n# Danipa Fintech Platform (added by make hosts-patch)\\n" >> /etc/hosts'; \
	    sudo sh -c 'cat $(HOSTS_SNIPPET) >> /etc/hosts'; \
	    echo "✓ /etc/hosts updated"; \
	  else \
	    echo "✓ Entries already present in /etc/hosts"; \
	  fi; \
	else \
	  echo ">> Non-Unix or unknown OS detected. Please patch hosts manually with admin privileges."; \
	  echo "   Open this file and append its contents to your system hosts file:"; \
	  echo "     $(HOSTS_SNIPPET)"; \
	  echo "   Windows path: C:\\\\Windows\\\\System32\\\\drivers\\\\etc\\\\hosts"; \
	fi

.PHONY: hosts-show
hosts-show: ## Show current host mappings for Danipa domains (from /etc/hosts)
	@grep -E 'danipa\.com' /etc/hosts || echo "(no danipa.com entries in /etc/hosts)"

##@ Developer QoL
.PHONY: dev-up-fast
dev-up-fast: up-core wait-core health ## Bring up core, wait, and run health checks

.PHONY: bootstrap
bootstrap: ## Create/ensure Keycloak realm+clients & seed Vault (idempotent)
	$(call hdr,Bootstrap Keycloak realm '$(REALM)' and seed Vault '$(MOUNT)' from $(SEEDS_DIR))
	@test -x "$(BOOTSTRAP_SCRIPT)" || (echo "!! $(BOOTSTRAP_SCRIPT) not found or not executable"; exit 1)
	BASE_URL="$(KC_EXT_BASE)" \
	VAULT_ADDR="$(VAULT_EXT)" \
	VAULT_CACERT="$(VAULT_CACERT)" \
	CURL_FORCE_RESOLVE="$(CURL_FORCE_RESOLVE)" \
	REALM="$(REALM)" ENV_NAME="$(ENV_NAME)" MOUNT="$(MOUNT)" \
	SEEDS_DIR="$(SEEDS_DIR)" WRITE_SECRETS="$(WRITE_SECRETS)" \
	KC_ADMIN_USER="$(KC_ADMIN_USER)" KC_ADMIN_PASS="$(KC_ADMIN_PASS)" \
	TOKEN="$(TOKEN)" \
	bash "$(BOOTSTRAP_SCRIPT)"

.PHONY: bootstrap-dry-run
bootstrap-dry-run: ## Dry-run bootstrap (no changes; shows what would be created/updated)
	$(call hdr,DRY-RUN Bootstrap)
	@test -x "$(BOOTSTRAP_SCRIPT)" || (echo "!! $(BOOTSTRAP_SCRIPT) not found or not executable"; exit 1)
	BASE_URL="$(KC_EXT_BASE)" \
	VAULT_ADDR="$(VAULT_EXT)" \
	VAULT_CACERT="$(VAULT_CACERT)" \
	CURL_FORCE_RESOLVE="$(CURL_FORCE_RESOLVE)" \
	REALM="$(REALM)" ENV_NAME="$(ENV_NAME)" MOUNT="$(MOUNT)" \
	SEEDS_DIR="$(SEEDS_DIR)" WRITE_SECRETS="$(WRITE_SECRETS)" \
	KC_ADMIN_USER="$(KC_ADMIN_USER)" KC_ADMIN_PASS="$(KC_ADMIN_PASS)" \
	TOKEN="$(TOKEN)" \
	bash "$(BOOTSTRAP_SCRIPT)" --dry-run

.PHONY: bootstrap-verify
bootstrap-verify: ## Verify: Keycloak well-known + Vault KV tree under secret/metadata/danipa/config
	$(call hdr,Keycloak well-known (external))
	@curl $(CURL_SILENT) --cacert "$(VAULT_CACERT)" \
	  --resolve keycloak.local.danipa.com:443:127.0.0.1 \
	  "$(KC_EXT_BASE)/realms/$(REALM)/.well-known/openid-configuration" | jq . || true
	$(call hdr,Vault KV paths under danipa/config (metadata list))
	@curl $(CURL_SILENT) --cacert "$(VAULT_CACERT)" \
	  --resolve vault.local.danipa.com:443:127.0.0.1 \
	  -H "X-Vault-Token: $$(jq -r '.root_token' infra/vault/keys/vault-keys.json 2>/dev/null)" \
	  "$(VAULT_EXT)/v1/secret/metadata/danipa/config?list=true" | jq . || true

.PHONY: verify-scope
verify-scope: ## Verify OAuth2 client scope for a given client ID and secret
	@test -n "$(CID)" || (echo "CID=<clientId> is required"; exit 2)
	@test -n "$(SEC)" || (echo "SEC=<clientSecret> is required"; exit 2)
	@test -x "$(SCRIPTS_DIR)/verify-scope.sh" || (echo "!! $(SCRIPTS_DIR)/verify-scope.sh not found or not executable"; exit 1)
	@REALM="$(REALM)" KC="$(KC)" "$(SCRIPTS_DIR)/verify-scope.sh" "$(CID)" "$(SEC)" "$(SCOPE)"

.PHONY: verify-scope-all
verify-scope-all: ## Verify OAuth2 client scopes for all configured clients using env, seeds, or live Keycloak secrets
	@test -x "$(SCRIPTS_DIR)/verify-scope.sh" || (echo "!! $(SCRIPTS_DIR)/verify-scope.sh not found or not executable"; exit 1)
	@ADMIN_URL="$(KC)"; REALM="$(REALM)"; \
	KC_ADMIN_USER="$(KC_ADMIN_USER)"; KC_ADMIN_PASS="$(KC_ADMIN_PASS)"; \
	SEEDS="$(SEEDS)"; ENV="$(ENV)"; \
	for c in $(CALLERS); do \
	  echo ""; echo "### $$c ###"; \
	  # 1) try ENV first
	  sec=""; case "$$c" in \
	    eureka-server)          sec="$${EUREKA_SERVER_CLIENT_SECRET:-}";; \
	    danipa-fintech-service) sec="$${DANIPA_FINTECH_SERVICE_CLIENT_SECRET:-}";; \
	  esac; \
	  # 2) try seeds if ENV empty
	  if [ -z "$$sec" ] && [ -f "$(SEEDS)" ]; then \
	    sec="$$(jq -r --arg c "$$c" --arg e "$(ENV)" '.paths[$$c, $$e].SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_CLIENT_SECRET // empty' "$(SEEDS)")"; \
	  fi; \
	  run_verify() { REALM="$$REALM" KC="$$ADMIN_URL" "$(SCRIPTS_DIR)/verify-scope.sh" "$$c" "$$1" "$(SCOPE)"; }; \
	  # 3) try with env/seed secret (if any)
	  if [ -n "$$sec" ]; then \
	    if run_verify "$$sec"; then continue; fi; \
	    echo "!! Seed/env secret failed for $$c; falling back to Keycloak Admin to fetch live secret..." >&2; \
	  else \
	    echo "!! No secret in env/seeds for $$c; fetching live secret from Keycloak Admin..." >&2; \
	  fi; \
	  # 4) Keycloak Admin fallback → fetch live secret and retry
	  admin_tok="$$(curl -sS -X POST "$$ADMIN_URL/realms/master/protocol/openid-connect/token" \
	    -H 'Content-Type: application/x-www-form-urlencoded' \
	    --data "client_id=admin-cli&username=$$KC_ADMIN_USER&password=$$KC_ADMIN_PASS&grant_type=password" \
	    | jq -r '.access_token // empty')"; \
	  if [ -z "$$admin_tok" ]; then echo "!! Could not obtain KC admin token from $$ADMIN_URL" >&2; exit 2; fi; \
	  cid="$$(curl -sS -H "Authorization: Bearer $$admin_tok" \
	    "$$ADMIN_URL/admin/realms/$$REALM/clients?clientId=$$c" | jq -r '.[0].id // empty')"; \
	  if [ -z "$$cid" ]; then echo "!! Client $$c not found in realm $$REALM" >&2; exit 2; fi; \
	  live_sec="$$(curl -sS -H "Authorization: Bearer $$admin_tok" \
	    "$$ADMIN_URL/admin/realms/$$REALM/clients/$$cid/client-secret" | jq -r '.value // empty')"; \
	  if [ -z "$$live_sec" ]; then echo "!! Could not fetch client-secret for $$c" >&2; exit 2; fi; \
	  if ! run_verify "$$live_sec"; then echo "!! Even live KC secret failed for $$c" >&2; exit 2; fi; \
	done


# Optional: after bootstrap, bounce config-server and test a fetch
.PHONY: config-reload
config-reload: ## Restart config-server and probe /actuator/health (through docker network)
	$(call hdr,Restart config-server)
	$(COMPOSE) up -d --no-deps --force-recreate config-server
	$(call hdr,Wait config-server)
	$(call wait_http,$(CONFIG_URL))
	$(call hdr,Config env excerpts (JWT + profiles))
	@curl $(CURL_SILENT) "$(CONFIG_URL)/actuator/env" \
	 | jq '.propertySources[].properties
	       | to_entries[]
	       | select(.key|test("SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT|active.profiles|spring.profiles.active"))' || true


# Create a timestamped filename unless OUT= is provided:
define _default_dump_name
$(BACKUP_DIR)/$$(date +'%Y-%m-%d_%H%M%S')_$(DB).sql.gz
endef

# -------------------------------------------------------------------
# Public target: do Vault policy attach + agent render + DB verify + pgAdmin wiring
.PHONY: setup-postgres-dev
setup-postgres-dev: vault-policy-attach agent-wait render-check pg-verify pgadmin-json pgadmin-restart
	@echo "✅ Postgres dev is reachable and pgAdmin is wired to $(PG_HOST):$(PG_PORT) under group '$(PGADMIN_GROUP)'."

# ---- 1) Ensure/attach Vault policy ------------------------------------------
vault-policy-attach:
	@echo "-> Ensuring Vault policy '$(VAULT_POLICY_NAME)' and attaching it to AppRole '$(APPROLE_NAME)'..."
	@docker exec -i $(VAULT_CONT) sh -lc '\
	  export VAULT_ADDR="https://127.0.0.1:8200" VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  printf "%s\n" \
	    "path \"$(KV_PATH_DATA)\" { capabilities = [\"read\"] }" \
	    "path \"secret/metadata/danipa/fintech/*\" { capabilities = [\"list\"] }" \
	    > /tmp/pg-read.hcl; \
	  vault policy write $(VAULT_POLICY_NAME) /tmp/pg-read.hcl >/dev/null; \
	  CUR=$$(vault read -field=policies auth/approle/role/$(APPROLE_NAME) 2>/dev/null || echo ""); \
	  NEW=$$(printf "%s,$(VAULT_POLICY_NAME)\n" "$$CUR" | tr -d "[],\" " | tr "," "\n" | awk "NF" | sort -u | paste -sd, -); \
	  vault write auth/approle/role/$(APPROLE_NAME) policies="$$NEW" >/dev/null; \
	  echo "   Attached policies: $$NEW" \
	'

# ---- 2) Wait for agent to render the template --------------------------------
.PHONY: agent-wait
agent-wait:
	@echo "-> Waiting for Vault agent to render POSTGRES_PASSWORD..."
	@docker compose --profile dev up -d $(AGENT_CONT) >/dev/null
	@bash -lc '\
	  for i in $$(seq 1 40); do \
	    if docker logs --tail=80 $(AGENT_CONT) 2>&1 | grep -q "rendered \"/vault/templates/postgres_password\.ctmpl\" => \"/opt/pg-secrets/POSTGRES_PASSWORD\""; then \
	      exit 0; \
	    fi; \
	    sleep 0.5; \
	  done; \
	echo "ERROR: agent did not render POSTGRES_PASSWORD in time" >&2; \
	  exit 1 \
	'

# ---- 3) Confirm the file looks sane (non-empty) ------------------------------
.PHONY: render-check
render-check:
	@echo "-> Checking rendered /opt/pg-secrets/POSTGRES_PASSWORD..."
	@docker exec -i $(AGENT_CONT) sh -lc 'test -s /opt/pg-secrets/POSTGRES_PASSWORD || { echo "Empty password file"; exit 1; }'
	@docker exec -i $(AGENT_CONT) sh -lc 'echo "   size: $$(wc -c < /opt/pg-secrets/POSTGRES_PASSWORD) bytes"'

# ---- 4) Verify DB login using the rendered password --------------------------
.PHONY: pg-verify
pg-verify:
	@echo "-> Verifying DB login with the rendered password..."
	@PASS="$$(docker exec $(AGENT_CONT) sh -lc 'cat /opt/pg-secrets/POSTGRES_PASSWORD')"; \
	[ -n "$$PASS" ] || { echo "ERROR: no password read from agent"; exit 1; }; \
	docker exec -e PGPASSWORD="$$PASS" $(PG_CONT) \
	  psql -h localhost -U $(DB_USER) -d $(DB_NAME) -c "select current_user, now();" >/dev/null && \
	echo "   OK: Connected as $(DB_USER) to $(DB_NAME)"

# ---- 5) Write pgAdmin servers.json -------------------------------------------
.PHONY: pgadmin-json
pgadmin-json:
	@mkdir -p ./pgadmin
	@echo "-> Writing ./pgadmin/servers.json (Group=$(PGADMIN_GROUP), Host=$(PG_HOST):$(PG_PORT))"
	@cat > ./pgadmin/servers.json <<-JSON
	{
	  "Servers": {
	    "1": {
	      "Group": "$(PGADMIN_GROUP)",
	      "Name": "$(PG_NAME)",
	      "Host": "$(PG_HOST)",
	      "Port": $(PG_PORT),
	      "MaintenanceDB": "$(DB_NAME)",
	      "Username": "$(DB_USER)",
	      "SSLMode": "prefer"
	    }
	  }
	}
	JSON


# ---- 6) Restart/refresh pgAdmin so it picks up servers.json ------------------
.PHONY: pg-restart
pgadmin-restart:
	@if [ "$(FORCE_PGADMIN_REIMPORT)" = "1" ]; then \
	  echo "-> Forcing pgAdmin to re-import servers.json (removing the actual pgAdmin data volume)"; \
	  cid=$$(docker compose --profile dev ps -q pgadmin 2>/dev/null || true); \
	  if [ -n "$$cid" ]; then docker compose --profile dev rm -sf pgadmin >/dev/null || true; fi; \
	  vol=$$(docker volume ls -q | while read v; do \
	    docker volume inspect $$v --format '{{json .Mountpoint}} {{json .Name}}' 2>/dev/null | \
	    awk -v tgt="/var/lib/pgadmin" '1' >/dev/null; done; \
	    docker inspect $${cid:-$$(docker ps -q --filter name=pgadmin)} \
	      --format '{{range .Mounts}}{{if eq .Destination "/var/lib/pgadmin"}}{{.Name}}{{end}}{{end}}' 2>/dev/null); \
	  if [ -z "$$vol" ]; then \
	    # Fallback: try to guess the compose-scoped name
	    vol=$$(docker volume ls -q | grep -E '_pgadmin_data$$' | head -n1); \
	  fi; \
	  if [ -n "$$vol" ]; then echo "   Removing volume: $$vol"; docker volume rm -f "$$vol" || true; else echo "   (No pgAdmin data volume found)"; fi; \
	fi
	@docker compose --profile dev up -d pgadmin
	@echo "-> Waiting for pgAdmin health..."
	@for i in $$(seq 1 40); do \
	  st=$$(docker ps --filter name=danipa-pgadmin --format '{{.Status}}'); \
	  echo "$$st" | grep -qi healthy && { echo "   ✓ pgAdmin healthy"; exit 0; }; \
	  sleep 2; \
	done; \
	echo "WARN: pgAdmin not healthy yet; open http://localhost:8081 to check."

# ---- Quick connect helper ---------------------------------------------------
.PHONY: pg-connect
pg-connect: ## Open interactive psql session using Vault-rendered password
	@PASS="$$(docker exec $(AGENT_CONT) sh -lc "cat /opt/pg-secrets/POSTGRES_PASSWORD")"; \
	[ -n "$$PASS" ] || { echo "ERROR: no password read from agent"; exit 1; }; \
	echo "-> Connecting to $(PG_CONT) as $(DB_USER) on $(DB_NAME) ..."; \
	docker run -it --rm --network $(DANIPA_NET) -e PGPASSWORD="$$PASS" postgres:17-alpine \
	  psql -h $(PG_CONT) -U $(DB_USER) -d $(DB_NAME)

# ---- Run a single SQL statement (non-interactive) ---------------------------
# Usage: make pg-query SQL="select current_user, now();"
.PHONY: pg-query
pg-query:
	@PASS="$$(docker exec $(AGENT_CONT) sh -lc "cat /opt/pg-secrets/POSTGRES_PASSWORD")"; \
	[ -n "$$PASS" ] || { echo "ERROR: no password read from agent"; exit 1; }; \
	docker run --rm --network $(DANIPA_NET) -e PGPASSWORD="$$PASS" postgres:17-alpine \
	  psql -h $(PG_CONT) -U $(DB_USER) -d $(DB_NAME) -c "$(SQL)"

# ---- Quick whoami (uses pg-query) ------------------------------------------
.PHONY: pg-whoami
pg-whoami:
	@$(MAKE) --no-print-directory pg-query SQL="select current_user, current_database(), now();"

.PHONY: pg-dump
pg-dump:  ## Dump $(DB) to a gzipped SQL file (uses OUT= to override path)
	@mkdir -p "$(BACKUP_DIR)"
	@OUT="$${OUT:-$(_default_dump_name)}"; \
	PASS="$$(docker exec $(AGENT_CONT) sh -lc "cat /opt/pg-secrets/POSTGRES_PASSWORD")"; \
	[ -n "$$PASS" ] || { echo "ERROR: no password read from agent"; exit 1; }; \
	echo "-> Dumping $(DB) from $(PG_CONT) to $$OUT ..."; \
	docker run --rm --network $(DANIPA_NET) -e PGPASSWORD="$$PASS" postgres:17-alpine \
	  pg_dump -h $(PG_CONT) -U $(DB_USER) -d "$(DB)" \
	    --clean --if-exists --no-owner --no-privileges \
	| gzip > "$$OUT"; \
	echo "✓ Wrote $$OUT"

# Usage:
#   make pg-restore FILE=backups/db/2025-10-03_133500_danipa_fintech_db_dev.sql.gz
# Optional overrides:
#   make pg-restore FILE=... DB=my_other_db
.PHONY: pg-restore
pg-restore:  ## Restore FILE into $(DB) (auto-detect .gz)
	@test -n "$(FILE)" || { echo "Usage: make pg-restore FILE=<dump.sql[.gz]> [DB=<dbname>]"; exit 2; }
	@test -f "$(FILE)" || { echo "ERROR: file not found: $(FILE)"; exit 2; }
	@PASS="$$(docker exec $(AGENT_CONT) sh -lc "cat /opt/pg-secrets/POSTGRES_PASSWORD")"; \
	[ -n "$$PASS" ] || { echo "ERROR: no password read from agent"; exit 1; }; \
	echo "-> Restoring $(FILE) into database '$(DB)' on $(PG_CONT) ..."; \
	if echo "$(FILE)" | grep -qi '\.gz$$'; then DECOMP="gzip -cd $(FILE)"; else DECOMP="cat $(FILE)"; fi; \
	$$DECOMP \
	| docker run --rm --network $(DANIPA_NET) -i -e PGPASSWORD="$$PASS" postgres:17-alpine \
	    psql -v ON_ERROR_STOP=1 -h $(PG_CONT) -U $(DB_USER) -d "$(DB)"; \
	echo "✓ Restore complete"

.PHONY: config-server-cert
config-server-cert: ## Issue Config Server TLS cert into infra/config-server/tls
	@test -x "$(CONFIG_CERT_SCRIPT)" || (echo "!! $(CONFIG_CERT_SCRIPT) missing/executable"; exit 1)
	SANS="$(CONFIG_SANS)" TLS_DIR="$(CONFIG_TLS_DIR)" "$(CONFIG_CERT_SCRIPT)" issue "$(CONFIG_CN)"

.PHONY: config-server-cert-verify
config-server-cert-verify:
	@openssl x509 -in "$(CONFIG_TLS_DIR)/server-fullchain.crt" -noout -subject -issuer -dates -ext subjectAltName || true

.PHONY: e2e
e2e: up-core bootstrap config-reload health ## Bring up core, bootstrap Kc+Vault, reload config, run health checks

##@ Fintech Service (compose exec)

.PHONY: fintech-service-up
fintech-service-up: ## Start danipa-fintech-service and wait for health
	@echo "-> Starting $(FIN_SERVICE) ..."
	@docker compose --profile dev up -d $(FIN_SERVICE)
	$(call wait_http,$(FINTECH_URL))

.PHONY: fintech-agent-up
fintech-agent-up: ## Start fintech Vault Agent and wait until it's authenticated/rendered
	@echo "-> Starting $(FIN_AGENT_CONT) ..."
	@docker compose --profile dev up -d $(FIN_AGENT_CONT)
	@echo "-> Waiting for $(FIN_AGENT_CONT) to authenticate & render ..."
	@bash -lc '\
	  for i in $$(seq 1 60); do \
	    LOGS="$$(docker logs --tail=200 $(FIN_AGENT_CONT) 2>&1)"; \
	    if echo "$$LOGS" | grep -qiE "authentication successful|token written|template server received new token|rendered "; then \
	      echo "   ✓ $(FIN_AGENT_CONT) is authenticated/rendered"; \
	      exit 0; \
	    fi; \
	    sleep 1; \
	  done; \
	  echo "ERROR: $(FIN_AGENT_CONT) did not finish auth/render in time" >&2; \
	  exit 1 \
	'

.PHONY: fintech-up
fintech-up: fintech-agent-up fintech-service-up ## Start agent first, then service

.PHONY: fintech-service-logs
fintech-service-logs: ## Tail service logs
	@docker compose logs -f $(FIN_SERVICE)

.PHONY: fintech-refresh
fintech-refresh: ## POST /ms/actuator/refresh inside the running service container
	@svcs="$$( $(COMPOSE) config --services )"; \
	svc="$$( printf '%s' '$(FIN_SERVICE)' | tr -d '\r' )"; \
	echo ">> FIN_SERVICE='$$svc'"; \
	echo "$$svcs" | grep -qx "$$svc" || { \
	  echo "ERROR: service '$$svc' not found."; \
	  echo "Detected services:"; echo "$$svcs" | sed 's/^/  - /'; \
	  echo ""; \
	  echo "Hint: run:  make fintech-refresh FIN_SERVICE=<one-of-the-above>"; \
	  exit 2; \
	}; \
	cid="$$( $(COMPOSE) ps -q $$svc )"; \
	[ -n "$$cid" ] || { echo "ERROR: service '$$svc' is not running. Start it: make fintech-service-up FIN_SERVICE=$$svc"; exit 3; }; \
	$(COMPOSE) exec $$svc \
	  sh -lc 'curl -sS -i -u act:act-pass -X POST http://localhost:8080/ms/actuator/refresh || exit $$?'

.PHONY: fintech-busrefresh
fintech-busrefresh: ## POST /ms/actuator/busrefresh inside the running service container (fan-out)
	@svcs="$$( $(COMPOSE) config --services )"; \
	svc="$$( printf '%s' '$(FIN_SERVICE)' | tr -d '\r' )"; \
	echo ">> FIN_SERVICE='$$svc'"; \
	echo "$$svcs" | grep -qx "$$svc" || { \
	  echo "ERROR: service '$$svc' not found."; \
	  echo "Detected services:"; echo "$$svcs" | sed 's/^/  - /'; \
	  echo ""; \
	  echo "Hint: run:  make fintech-busrefresh FIN_SERVICE=<one-of-the-above>"; \
	  exit 2; \
	}; \
	cid="$$( $(COMPOSE) ps -q $$svc )"; \
	[ -n "$$cid" ] || { echo "ERROR: service '$$svc' is not running. Start it: make fintech-service-up FIN_SERVICE=$$svc"; exit 3; }; \
	$(COMPOSE) exec $$svc \
	  sh -lc 'curl -sS -i -u act:act-pass -X POST http://localhost:8080/ms/actuator/busrefresh || exit $$?'

.PHONY: fintech-show-prop
fintech-show-prop: ## Show PROP from /ms/actuator/env inside container (default: logging.level.com.danipa.fintech)
	@svcs="$$( $(COMPOSE) config --services )"; \
	svc="$$( printf '%s' '$(FIN_SERVICE)' | tr -d '\r' )"; \
	echo ">> FIN_SERVICE='$$svc'"; \
	[ -n "$$( $(COMPOSE) ps -q $$svc )" ] || { echo "ERROR: $$svc not running"; exit 3; }; \
	curl -sS -u $(ACT_USER):$(ACT_PASS) http://localhost:8080/ms/actuator/env | \
	jq -r '.propertySources[] | select(.name|test("(applicationConfig|configserver):.*")) \
	       | .properties["$(PROP)"].value // empty' | \
	awk 'NF{print; found=1} END{if(!found) print "NOT FOUND"}' \
	| sed 's/^/$(PROP)=/'

##@ Actuator (external URL)

.PHONY: fintech-logger-get
fintech-logger-get: ## Get logger levels at /ms/actuator/loggers [LOGGER=com.danipa.fintech]
	@$(ACT_CURL) $(ACT_URL)/loggers/$(LOGGER) | $(JQ)

.PHONY: fintech-logger-set
fintech-logger-set: ## Set logger level: LEVEL=<TRACE|DEBUG|INFO|WARN|ERROR|OFF> [LOGGER=...]
	@test -n "$(LEVEL)" || { echo "Usage: make fintech-logger-set LEVEL=<TRACE|DEBUG|INFO|WARN|ERROR|OFF> [LOGGER=...]"; exit 2; }
	@$(ACT_CURL) -H 'Content-Type: application/json' \
	  -d '{"configuredLevel":"$(LEVEL)"}' \
	  -X POST $(ACT_URL)/loggers/$(LOGGER) | $(JQ) || true

.PHONY: fintech-logger-reset
fintech-logger-reset: ## Reset logger to INFO [LOGGER=com.danipa.fintech]
	@$(ACT_CURL) -H 'Content-Type: application/json' \
	  -d '{"configuredLevel":"INFO"}' \
	  -X POST $(ACT_URL)/loggers/$(LOGGER) | $(JQ) || true

.PHONY: fintech-act-health
fintech-act-health: ## GET /ms/actuator/health
	@$(ACT_CURL) $(ACT_URL)/health | $(JQ)

.PHONY: fintech-act-info
fintech-act-info: ## GET /ms/actuator/info
	@$(ACT_CURL) $(ACT_URL)/info | $(JQ)

.PHONY: fintech-act-env
fintech-act-env: ## GET /ms/actuator/env
	@$(ACT_CURL) $(ACT_URL)/env | $(JQ)

.PHONY: fintech-act-env-key
fintech-act-env-key: ## GET /ms/actuator/env/{KEY}  (e.g., KEY=spring.profiles.active)
	@test -n "$(KEY)" || { echo "Usage: make fintech-act-env-key KEY=<property.key>"; exit 2; }
	@$(ACT_CURL) $(ACT_URL)/env/$(KEY) | $(JQ)

.PHONY: fintech-act-metrics
fintech-act-metrics: ## List metrics: GET /ms/actuator/metrics
	@$(ACT_CURL) $(ACT_URL)/metrics | $(JQ)

.PHONY: fintech-act-metric
fintech-act-metric: ## GET /ms/actuator/metrics/{NAME} [Q='?tag=k:v&tag=k2:v2']
	@test -n "$(NAME)" || { echo "Usage: make fintech-act-metric NAME=<metric.name> [Q=?tag=k:v]"; exit 2; }
	@$(ACT_CURL) "$(ACT_URL)/metrics/$(NAME)$(Q)" | $(JQ)

.PHONY: fintech-act-mappings
fintech-act-mappings: ## GET /ms/actuator/mappings
	@$(ACT_CURL) $(ACT_URL)/mappings | $(JQ)

.PHONY: fintech-act-beans
fintech-act-beans: ## GET /ms/actuator/beans
	@$(ACT_CURL) $(ACT_URL)/beans | $(JQ)

.PHONY: fintech-act-configprops
fintech-act-configprops: ## GET /ms/actuator/configprops
	@$(ACT_CURL) $(ACT_URL)/configprops | $(JQ)

.PHONY: fintech-act-refresh
fintech-act-refresh: ## POST /ms/actuator/refresh (external)
	@$(ACT_CURL) -X POST $(ACT_URL)/refresh -i

.PHONY: fintech-act-busrefresh
fintech-act-busrefresh: ## POST /ms/actuator/busrefresh (external fan-out)
	@$(ACT_CURL) -X POST $(ACT_URL)/busrefresh -i

# Probe DB permissions (dev defaults)
##@ Database DEV

.PHONY: probe-db-perms
probe-db-perms: ## Probe DB grants/roles for $(APP_ENV) via scripts/qa/probe-db-permissions.sh
	@bash infra/postgres/init/dev/probe_db_perms.sh

# Example staging invocation:
# make probe-db-perms \
#   POSTGRES_CONTAINER=danipa-postgres-staging \
#   DB_NAME=danipa_fintech_db_staging \
#   OWNER_ROLE=danipa_owner_staging \
#   APP_ROLE=danipa_app_staging \
#   RO_ROLE=danipa_ro_staging \
#   MIGRATOR_ROLE=danipa_migrator_staging \
#   APP_SCHEMAS="fintech core payments momo webhooks ops" \
#   RO_ONLY_SCHEMAS="audit"

.PHONY: db-bootstrap
db-bootstrap: ## Run the database bootstrap script for the current APP_ENV
	@chmod +x infra/postgres/init/$(APP_ENV)/010-bootstrap-db.sh
	@PGHOST=$(PGHOST) PGPORT=$(PGPORT) PGUSER=$(PGUSER) PGPASSWORD=$(PGPASSWORD) \
	infra/postgres/init/$(APP_ENV)/010-bootstrap-db.sh

.PHONY: start-db stop-db
start-db: ## Start the database stack for the current APP_ENV using the dev script
	@APP_ENV=$(APP_ENV) ./scripts/dev/start-db-stack.sh
stop-db: ## Stop the database stack for the current APP_ENV using the dev script
	@./scripts/dev/stop-db-stack.sh


# ---- begin ELK block guard ----
ifndef ELK_MK_LOADED
ELK_MK_LOADED := 1

##@ Meta (ELK)
.PHONY: elk-help elk-env
elk-help: ## Show categorized help for ELK targets only
	@awk 'BEGIN {FS=":.*##"; ORS=""; print "\n\033[1mELK targets\033[0m\n"} \
	/^##@/ { gsub(/^##@ /,"",$$0); printf "\n\033[1m%s\033[0m\n", $$0 } \
	/^[a-zA-Z0-9_.-]+:.*##/ { printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST); echo

elk-env: ## Print effective ELK environment variables
	@echo "ES_URL=$(ES_URL)"; \
	echo "KIBANA_URL=$(KIBANA_URL)"; \
	echo "LOGSTASH_URL=$(LOGSTASH_URL)"; \
	echo "WAIT_STATUS=$(WAIT_STATUS)"; \
	echo "SNAPSHOT_REPO=$(SNAPSHOT_REPO)"; \
	echo "ES_SNAPSHOT_FS_PATH=$(ES_SNAPSHOT_FS_PATH)"; \
	echo "INDICES=$(INDICES)"; \
	echo "SNAP_NAME=$(SNAP_NAME)"; \
	echo "ES_API_KEY=$(if $(ES_API_KEY),<set>,<empty>)"; \
	echo "ES_USER=$(if $(ES_USER),<set>,<empty>)"; \
	echo "ES_PASSWORD=$(if $(ES_PASSWORD),<set>,<empty>)"; \
	echo "ES_INSECURE=$(if $(ES_INSECURE),1,0)"


# -------- Health ----------
##@ Health
.PHONY: es-health kibana-health logstash-health elk-health es-wait elk-detect

elk-detect: ## Detect HTTP/HTTPS and auth requirements for ES
	@echo ">> Probing $(ES_URL) (dockerized=$(if $(USE_DOCKER_CURL),yes,no))"
	@$(call curl_es) -m 5 $(ES_URL) || true
	@echo "\n>> /_cluster/health"
	@$(call curl_es) -m 5 "$(ES_URL)/_cluster/health" || true
	@echo "\nHints:"
	@echo " - If you see JSON and status, it's HTTP/no-auth."
	@echo " - If you see 'security_exception', set ES_API_KEY or ES_USER/ES_PASSWORD."
	@echo " - If TLS errors occur, switch ES_URL to https://... and set ES_INSECURE=1 (dev only)."


es-health: ## Print Elasticsearch cluster status (red/yellow/green)
	@echo ">> Elasticsearch cluster health ($(ES_URL))"
	@$(call curl_es) "$(ES_URL)/_cluster/health?pretty" | jq -r '.status'

kibana-health: ## Print Kibana overall level from /api/status
	@echo ">> Kibana status ($(KIBANA_URL))"
	@$(call curl_es) "$(KIBANA_URL)/api/status" | jq -r '.status.overall.level' || true

logstash-health: ## Print Logstash node status from /_node
	@echo ">> Logstash node ($(LOGSTASH_URL))"
	@$(call curl_es) "$(LOGSTASH_URL)/_node" | jq -r '.status' || true

elk-health: es-health kibana-health logstash-health ## Run health checks for ES, Kibana, and Logstash

es-wait: ## Wait until ES cluster health reaches $(WAIT_STATUS) or green (timeout ~120s)
	@echo ">> Waiting for cluster status $(WAIT_STATUS) ..."
	@for i in $$(seq 1 60); do \
	  s=$$($(call curl_es) "$(ES_URL)/_cluster/health" | jq -r '.status'); \
	  echo "attempt $$i: status=$$s"; \
	  [[ "$$s" == "$(WAIT_STATUS)" || "$$s" == "green" ]] && exit 0; \
	  sleep 2; \
	done; \
	echo "Cluster not $(WAIT_STATUS)/green after timeout" && exit 1

# -------- Snapshot repo --------
##@ Snapshot repository
.PHONY: es-snapshot-repo-fs es-snapshot-repo-s3 es-snapshot-repo-get

es-snapshot-repo-fs: ## Create/Update a filesystem snapshot repo at $(ES_SNAPSHOT_FS_PATH)
	@echo ">> Create/Update FS snapshot repo $(SNAPSHOT_REPO) at $(ES_SNAPSHOT_FS_PATH)"
	@$(call curl_es) -X PUT "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)" \
	 -H "Content-Type: application/json" \
	 -d '{"type":"fs","settings":{"location":"$(ES_SNAPSHOT_FS_PATH)","compress":true}}' | jq

es-snapshot-repo-s3: ## Create/Update an S3 snapshot repo (requires S3_BUCKET, optional S3_BASE_PATH, S3_REGION)
	@if [ -z "$$S3_BUCKET" ]; then echo "S3_BUCKET required"; exit 1; fi
	@echo ">> Create/Update S3 snapshot repo $(SNAPSHOT_REPO) in bucket $$S3_BUCKET"
	@$(call curl_es) -X PUT "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)" \
	 -H "Content-Type: application/json" \
	 -d '{"type":"s3","settings":{"bucket":"'"$$S3_BUCKET"'","base_path":"'"$$S3_BASE_PATH"'", "region":"'"$$S3_REGION"'"}}' | jq

es-snapshot-repo-get: ## Show the current snapshot repository configuration
	@$(call curl_es) "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)?pretty" | jq

# -------- Snapshot create/verify/status --------
##@ Snapshot
.PHONY: es-snapshot-create es-snapshot-status es-snapshot-list es-snapshot-verify

es-snapshot-create: es-wait ## Create a snapshot ($(SNAP_NAME)) in repo $(SNAPSHOT_REPO); waits for completion
	@echo ">> Creating snapshot $(SNAP_NAME) in repo $(SNAPSHOT_REPO)"
	@$(call curl_es) -X PUT "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)/$(SNAP_NAME)?wait_for_completion=true" \
	 -H "Content-Type: application/json" \
	 -d '{"indices":"*","ignore_unavailable":true,"include_global_state":true}' | jq '.snapshot.state'

es-snapshot-status: ## Show in-flight snapshot status
	@$(call curl_es) "$(ES_URL)/_snapshot/_status?pretty" | jq

es-snapshot-list: ## List snapshots in repo $(SNAPSHOT_REPO) (latest first)
	@$(call curl_es) "$(ES_URL)/_cat/snapshots/$(SNAPSHOT_REPO)?s=end_time:desc&h=id,start_time,end_time,state" | column -t

es-snapshot-verify: ## Verify a specific snapshot by name (requires SNAP_NAME)
	@if [ -z "$(SNAP_NAME)" ]; then echo "SNAP_NAME required"; exit 1; fi
	@echo ">> Verify snapshot $(SNAP_NAME)"
	@$(call curl_es) "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)/$(SNAP_NAME)?pretty" | jq -r '.snapshots[0].state'

# -------- Restore --------
##@ Restore
.PHONY: es-restore-latest es-restore es-restore-verify

es-restore-latest: ## Restore the latest successful snapshot (indices=$(INDICES)) and wait for health
	@echo ">> Finding latest snapshot in $(SNAPSHOT_REPO)"
	@SN=$$($(call curl_es) "$(ES_URL)/_cat/snapshots/$(SNAPSHOT_REPO)?s=end_time:desc&h=id,state" | awk '$$2=="SUCCESS"{print $$1; exit}'); \
	if [ -z "$$SN" ]; then echo "No successful snapshots found"; exit 1; fi; \
	echo "Restoring snapshot: $$SN"; \
	$(call curl_es) -X POST "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)/$$SN/_restore" \
	 -H "Content-Type: application/json" \
	 -d '{"indices":"$(INDICES)","ignore_unavailable":true,"include_global_state":true,"partial":false,"rename_pattern":".*","rename_replacement":"$$0"}' | jq; \
	$(MAKE) es-wait

# Restore by explicit name: make es-restore SNAP_NAME=manual-20250101T010203 INDICES="logs-*"
es-restore: ## Restore a snapshot by name (requires SNAP_NAME; set INDICES to scope) and wait for health
	@if [ -z "$(SNAP_NAME)" ]; then echo "SNAP_NAME required"; exit 1; fi
	@echo ">> Restoring $(SNAP_NAME) (indices=$(INDICES))"
	@$(call curl_es) -X POST "$(ES_URL)/_snapshot/$(SNAPSHOT_REPO)/$(SNAP_NAME)/_restore" \
	 -H "Content-Type: application/json" \
	 -d '{"indices":"$(INDICES)","ignore_unavailable":true,"include_global_state":true,"partial":false}' | jq
	@$(MAKE) es-wait

es-restore-verify: ## List indices after restore
	@echo ">> Indices after restore"
	@$(call curl_es) "$(ES_URL)/_cat/indices?v"

# -------- Composite validation --------
##@ Composite
.PHONY: elk-snapshot-validate

elk-snapshot-validate: es-health es-snapshot-create es-snapshot-verify es-snapshot-list ## Create a snapshot and validate (dev-friendly smoke test)
	@echo ">> Snapshot validation complete for $(SNAP_NAME) in repo $(SNAPSHOT_REPO)"
# ---- end ELK block guard ----
endif

##@ Git Submodules Sync
SUBMODULES := $(shell git config --file .gitmodules --get-regexp path | awk '{print $$2}')

.PHONY: submodules-sync
submodules-sync: ## Commit/push dirty submodules; bump pointers in superproject
	@set -e; \
	git submodule foreach '\
	  # Ensure on a branch (prefer main), set upstream if missing
	  if ! git symbolic-ref -q HEAD >/dev/null; then \
	    echo "[FIX] $$name: detached -> main"; \
	    git checkout -B main; \
	  fi; \
	  BR=$$(git rev-parse --abbrev-ref HEAD); \
	  git fetch origin >/dev/null 2>&1 || true; \
	  # If upstream not set, set it to origin/$$BR
	  if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then \
	    git branch --set-upstream-to=origin/$$BR $$BR || true; \
	  fi; \
	  # Commit changes (incl. renames/deletes) only if present
	  git add -A; \
	  if ! git diff --cached --quiet || ! git diff --quiet; then \
	    git commit -m "Chore: sync $$(date +%F)" || true; \
	    git push --no-verify --set-upstream origin $$BR; \
	  else \
	    echo "[CLEAN] $$name"; \
	  fi'
	@echo "== Bump submodule pointers in superproject =="; \
	git add $(SUBMODULES); \
	if ! git diff --cached --quiet; then \
	  git commit -m "Chore: bump submodule pointers ($$(date +%F))"; \
	  git push --no-verify origin main; \
	else \
	  echo "[CLEAN] superproject"; \
	fi

.PHONY: submodules-check
submodules-check: ## Show branch, upstream, and dirty status for each submodule
	@set -e; \
	git submodule foreach '\
	  BR=$$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "DETACHED"); \
	  UP=$$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "NO-UPSTREAM"); \
	  DIRTY="clean"; \
	  (! git diff --quiet || ! git diff --cached --quiet || [ -n "$$(git ls-files --others --exclude-standard)" ]) && DIRTY="dirty"; \
	  echo "$$name  branch=$$BR  upstream=$$UP  $$DIRTY"; \
	'

.PHONY: submodules-diff
submodules-diff: ## Show diff for all submodules
	@git diff --submodule=log --cached || true