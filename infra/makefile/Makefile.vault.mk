# ---- Makefile.vault.mk ----
ifndef VAULT_MK_LOADED
VAULT_MK_LOADED := 1

##@ Vault Management (init, unseal, health, certs, seeding)

# ------- Core defaults -------
VAULT_SERVICE      ?= vault
VAULT_CONT         ?= danipa-vault
AGENT_CONT         ?= postgres-agent
NET                ?= danipa-net
TLS_DIR            ?= infra/vault/tls
VAULT_CACERT       ?= $(TLS_DIR)/root_ca.crt
VAULT_EXT          ?= https://vault.local.danipa.com
VAULT_ADDR         ?= https://127.0.0.1:8200
UNSEAL_KEY_FILE    ?= infra/vault/keys/vault-unseal.key
VAULT_CERT_SCRIPT  ?= infra/vault/scripts/cert/vault_cert.sh
WRITE_SECRETS      ?= infra/vault/scripts/write-secrets.sh
SEEDS_DIR          ?= infra/vault/seeds
DEV_JSON           ?= dev.json
APPROLE_NAME       ?= fintech-role-dev
VAULT_POLICY_NAME  ?= pg-read
KV_PATH_DATA       ?= secret/data/danipa/fintech/dev
KV_PATH_HUMAN      ?= secret/danipa/fintech/dev

# -------- TLS / cert defaults --------
CN          ?= vault.local.danipa.com
SANS        ?= vault.local.danipa.com vault localhost 127.0.0.1
EXTRA_SANS  ?=
SANS_FINAL  := $(SANS) $(EXTRA_SANS)

# derive extras for script input
define FILTER_EXTRAS
  awk '{
    for (i=1;i<=NF;i++){
      s=$$i;
      if (s!="$(CN)" && s!="vault" && s!="localhost" && s!="127.0.0.1") print s
    }
  }' <<< "$(SANS_FINAL)" | xargs
endef
SCRIPT_SANS := $(shell $(FILTER_EXTRAS))

# -------- Helpers --------
CURL_FLAGS     ?= -fsS
CURL_RETRY_FLAGS := \
  --fail --retry 60 --retry-delay 1 --retry-max-time 120 \
  --retry-all-errors --retry-connrefused
CURL_SILENT    ?= -fsS --connect-timeout 3 --max-time 5
HEALTH_URL     := https://$(CN):18300/v1/sys/health?standbyok=true&perfstandbyok=true&sealedcode=200&uninitcode=200&drsecondarycode=200

# -------- PHONY targets --------
.PHONY: vault-init vault-unseal vault-unseal-3 vault-status vault-health \
        vault-cert vault-cert-verify vault-cert-dry-run \
        vault-seed vault-verify vault-policy-attach vault-clean

##@ Initialization / Unseal
vault-init: ## Initialize Vault once (writes infra/vault/keys/*)
	@echo ">> Initializing Vault ..."
	@mkdir -p infra/vault/keys
	@docker compose exec -T $(VAULT_SERVICE) sh -lc '\
	  export VAULT_ADDR="https://127.0.0.1:8200" VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  vault operator init -format=json' > infra/vault/keys/vault-init.json
	@jq -r '.unseal_keys_b64[]' infra/vault/keys/vault-init.json > infra/vault/keys/unseal-keys.txt
	@jq -r '{root_token, unseal_keys_b64}' infra/vault/keys/vault-init.json > infra/vault/keys/vault-keys.json
	@head -n1 infra/vault/keys/unseal-keys.txt > $(UNSEAL_KEY_FILE)
	@chmod 0400 infra/vault/keys/vault-keys.json $(UNSEAL_KEY_FILE)
	@echo "✓ Keys saved under infra/vault/keys/ (guard securely)"

vault-unseal: ## Unseal Vault using key file or UNSEAL_KEY var
	@KEY="$${UNSEAL_KEY:-$$(tr -d '\r\n ' < $(UNSEAL_KEY_FILE) 2>/dev/null)}"; \
	test -n "$$KEY" || { echo "!! Missing unseal key"; exit 1; }; \
	echo ">> Unsealing Vault ..."; \
	docker compose exec -T $(VAULT_SERVICE) sh -lc \
	  "vault operator unseal -address=https://127.0.0.1:8200 -tls-skip-verify $$KEY"

vault-unseal-3: ## Apply first three unseal keys sequentially
	@for i in 1 2 3; do \
	  KEY="$$(sed -n "$${i}p" infra/vault/keys/unseal-keys.txt | tr -d '\r\n ')"; \
	  [ -n "$$KEY" ] || { echo "Missing key $$i"; exit 2; }; \
	  $(MAKE) --no-print-directory UNSEAL_KEY="$$KEY" vault-unseal; \
	done

vault-status: ## Show seal status (ignoring TLS verify)
	@docker compose exec -T $(VAULT_SERVICE) sh -lc \
	  'vault status -address=https://127.0.0.1:8200 -tls-skip-verify || true'

##@ Health / Cert
vault-health: ## Check Vault health API via TLS (SNI + CA)
	@curl -sS --cacert "$(TLS_DIR)/root_ca.crt" \
	  --resolve "$(CN)":18300:127.0.0.1 "$(HEALTH_URL)" | jq

vault-cert: ## Issue Vault TLS cert via script, restart Vault, health-check
	@echo ">> Issuing Vault cert for CN=$(CN)"
	@echo ">> Extra SANs: $(SCRIPT_SANS)"
	@test -x "$(VAULT_CERT_SCRIPT)" || (echo "!! $(VAULT_CERT_SCRIPT) not found"; exit 1)
	SANS="$(SCRIPT_SANS)" "$(VAULT_CERT_SCRIPT)" issue "$(CN)"
	@echo ">> Restarting Vault..."
	docker compose up -d --no-deps --force-recreate $(VAULT_SERVICE)
	@echo ">> Checking Vault health ..."
	curl -sS --cacert "$(TLS_DIR)/root_ca.crt" \
	  --resolve "$(CN)":18300:127.0.0.1 "$(HEALTH_URL)" | jq .

vault-cert-dry-run: ## Issue cert only, no restart
	@test -x "$(VAULT_CERT_SCRIPT)" || (echo "!! $(VAULT_CERT_SCRIPT) not found"; exit 1)
	SANS="$(SCRIPT_SANS)" "$(VAULT_CERT_SCRIPT)" issue "$(CN)"
	@$(MAKE) vault-cert-verify

vault-cert-verify: ## Display cert details
	@openssl x509 -in "$(TLS_DIR)/server-fullchain.crt" -noout \
	  -subject -issuer -dates -ext subjectAltName || true

##@ Seeding / Policies
vault-seed: ## Seed secrets into Vault (dev)
	@TOKEN=$$(jq -r '.root_token' infra/vault/keys/vault-keys.json); \
	test -n "$$TOKEN"; \
	test -x "$(WRITE_SECRETS)" || { echo "!! $(WRITE_SECRETS) missing"; exit 1; }; \
	VAULT_ADDR="$(VAULT_EXT)" VAULT_CACERT="$(VAULT_CACERT)" \
	VAULT_FORCE_RESOLVE="vault.local.danipa.com:443:127.0.0.1" \
	ENVS=dev TOKEN="$$TOKEN" bash "$(WRITE_SECRETS)"

vault-verify: ## Verify read access (dry-run)
	@TOKEN=$$(jq -r '.root_token' infra/vault/keys/vault-keys.json); \
	test -n "$$TOKEN"; \
	VERIFY_ONLY=true ENVS=dev TOKEN="$$TOKEN" bash "$(WRITE_SECRETS)"

vault-policy-attach: ## Attach read policy to AppRole
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
	  echo "Attached: $$NEW"'

vault-clean: ## Remove generated key files (DANGEROUS)
	@rm -rf infra/vault/keys/*
	@echo "🧹 Vault keys cleared (re-init required)."

endif
