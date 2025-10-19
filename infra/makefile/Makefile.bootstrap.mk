# ---- Makefile.bootstrap.mk ----
ifndef BOOTSTRAP_MK_LOADED
BOOTSTRAP_MK_LOADED := 1

##@ Bootstrap & Certs (Keycloak/Vault + Config Server TLS)

# ---- Inputs / scripts ----
BOOTSTRAP_SCRIPT ?= infra/vault/scripts/bootstrap-keycloak-and-vault.sh
KC_EXT_BASE      ?= https://keycloak.local.danipa.com
VAULT_EXT        ?= https://vault.local.danipa.com
VAULT_CACERT     ?= infra/vault/tls/root_ca.crt
CURL_FORCE_RESOLVE ?= keycloak.local.danipa.com:443:127.0.0.1;vault.local.danipa.com:443:127.0.0.1

REALM          ?= danipa
ENV_NAME       ?= dev
MOUNT          ?= secret
SEEDS_DIR      ?= infra/vault/seeds
WRITE_SECRETS  ?= ./infra/vault/scripts/write-secrets.sh
KC_ADMIN_USER  ?= admin
KC_ADMIN_PASS  ?= admin
TOKEN          ?=

# Config Server TLS issuance
CONFIG_CERT_SCRIPT ?= infra/config-server/scripts/cert/config_server_cert.sh
CONFIG_TLS_DIR     ?= infra/config-server/tls
CONFIG_CN          ?= config-server
CONFIG_SANS        ?= config.local.danipa.com

# Helper curl
CURL_SILENT ?= -fsS --connect-timeout 3 --max-time 5

.PHONY: bootstrap bootstrap-dry-run bootstrap-verify \
        config-server-cert config-server-cert-verify \
        config-reload

bootstrap: ## Create/ensure Keycloak realm/clients & seed Vault (idempotent)
	@echo "== Bootstrap Keycloak realm '$(REALM)' & seed Vault '$(MOUNT)' from $(SEEDS_DIR) =="
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

bootstrap-dry-run: ## Dry-run bootstrap; show actions without changing state
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

bootstrap-verify: ## Verify KC well-known & Vault KV tree exists
	@echo "== Keycloak well-known =="
	@curl $(CURL_SILENT) --cacert "$(VAULT_CACERT)" \
	  --resolve keycloak.local.danipa.com:443:127.0.0.1 \
	  "$(KC_EXT_BASE)/realms/$(REALM)/.well-known/openid-configuration" | jq . || true
	@echo "== Vault KV metadata list (danipa/config) =="
	@curl $(CURL_SILENT) --cacert "$(VAULT_CACERT)" \
	  --resolve vault.local.danipa.com:443:127.0.0.1 \
	  -H "X-Vault-Token: $$(jq -r '.root_token' infra/vault/keys/vault-keys.json 2>/dev/null)" \
	  "$(VAULT_EXT)/v1/secret/metadata/danipa/config?list=true" | jq . || true

config-server-cert: ## Issue Config Server TLS cert into $(CONFIG_TLS_DIR)
	@test -x "$(CONFIG_CERT_SCRIPT)" || (echo "!! $(CONFIG_CERT_SCRIPT) missing/executable"; exit 1)
	SANS="$(CONFIG_SANS)" TLS_DIR="$(CONFIG_TLS_DIR)" "$(CONFIG_CERT_SCRIPT)" issue "$(CONFIG_CN)"

config-server-cert-verify: ## Verify Config Server TLS cert in $(CONFIG_TLS_DIR)
	@openssl x509 -in "$(CONFIG_TLS_DIR)/server-fullchain.crt" -noout -subject -issuer -dates -ext subjectAltName || true

# (kept here because it’s part of bootstrap UX)
COMPOSE ?= docker compose
CONFIG_URL ?= http://config-server:8088

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

config-reload: ## Restart config-server and probe health
	@echo "== Restart config-server =="
	@$(COMPOSE) up -d --no-deps --force-recreate config-server
	@$(call wait_http,$(CONFIG_URL))

endif
