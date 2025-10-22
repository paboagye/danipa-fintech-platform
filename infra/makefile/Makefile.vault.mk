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

# CLI wrapper (run *one full command string* inside the container)
VAULT_CMD ?= docker exec -i $(VAULT_CONT) sh -lc

# -------- TLS / cert defaults --------
CN          ?= vault.local.danipa.com
SANS        ?= vault.local.danipa.com vault localhost 127.0.0.1
EXTRA_SANS  ?=
SANS_FINAL  := $(SANS) $(EXTRA_SANS)

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
        vault-seed vault-verify vault-policy-attach vault-clean \
        vault-env vault-ls vault-read vault-read-json vault-token vault-whoami vault-cli

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
	  echo ">> Unsealing with key $$i ..."; \
	  docker compose exec -T $(VAULT_SERVICE) sh -lc \
	    "vault operator unseal -address=https://127.0.0.1:8200 -tls-skip-verify $$KEY" || exit $$?; \
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
	VERIFY_ONLY=true ENVS=dev TOKEN="$$TOKEN" \
	VAULT_ADDR="$(VAULT_EXT)" VAULT_CACERT="$(VAULT_CACERT)" \
	VAULT_FORCE_RESOLVE="vault.local.danipa.com:443:127.0.0.1" \
	bash "$(WRITE_SECRETS)"

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

##@ Auth / Tokens

ROOT_TOKEN_FILE ?= infra/vault/keys/vault-keys.json
VAULT_LOGIN_TOKEN ?=
VAULT_CHILD_TTL ?= 24h
VAULT_CHILD_DISPLAY ?= cli-browse

.PHONY: vault-login-root vault-login vault-mint-token vault-whoami vault-logout

vault-login-root: ## Write the saved root token into /root/.vault-token (container)
	@TOKEN=$$(jq -r '.root_token' "$(ROOT_TOKEN_FILE)"); \
	test -n "$$TOKEN" || { echo "!! root token not found in $(ROOT_TOKEN_FILE)"; exit 2; }; \
	$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	              printf "%s\n" '"$$TOKEN"' > /root/.vault-token && chmod 0600 /root/.vault-token && echo "✓ root token installed"'

vault-login: ## Write an explicit token into /root/.vault-token (make vault-login VAULT_LOGIN_TOKEN=...)
	@test -n "$(VAULT_LOGIN_TOKEN)" || { echo "Usage: make vault-login VAULT_LOGIN_TOKEN=<token>"; exit 2; }
	@$(VAULT_CMD) 'printf "%s\n" "$(VAULT_LOGIN_TOKEN)" > /root/.vault-token && chmod 0600 /root/.vault-token && echo "✓ token installed"'

vault-mint-token: ## Mint a scoped token with policy $(VAULT_POLICY_NAME) and install it
	@$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  t=$$(vault token create -format=json -policy=$(VAULT_POLICY_NAME) -ttl=$(VAULT_CHILD_TTL) -display-name=$(VAULT_CHILD_DISPLAY) | jq -r .auth.client_token); \
	  test -n "$$t" || { echo "!! failed to mint token"; exit 3; }; \
	  printf "%s\n" "$$t" > /root/.vault-token && chmod 0600 /root/.vault-token; \
	  echo "✓ minted token (policy=$(VAULT_POLICY_NAME), ttl=$(VAULT_CHILD_TTL)) and installed"; \
	  echo "→ token prefix: $${t:0:16}..."'

vault-whoami: ## Show current token identity (inside container)
	@$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; vault token lookup || exit $$?'

vault-logout: ## Remove /root/.vault-token from container
	@$(VAULT_CMD) 'rm -f /root/.vault-token && echo "✓ removed /root/.vault-token"'

##@ Inspection / Mounts

.PHONY: vault-mounts vault-ls-any vault-ls-parent vault-put vault-del vault-purge
vault-mounts: ## Show secret engines and whether 'secret/' is kv v2
	@$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  vault secrets list -detailed || exit $$?'

vault-ls-any: ## List arbitrary path (KV v2): make vault-ls-any SECRET_PATH=secret|secret/danipa|secret/danipa/fintech
	@SECRET_PATH="$${SECRET_PATH:-secret}"; \
	echo "→ Listing: $$SECRET_PATH"; \
	$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  P="'"$$SECRET_PATH"'"; \
	  case "$$P" in \
	    secret|secret/)  TARGET="secret/";; \
	    secret/*)        TARGET="secret/$${P#secret/}";; \
	    *)               echo "!! SECRET_PATH must start with secret"; exit 2;; \
	  esac; \
	  vault kv list "$$TARGET"'

vault-ls-parent: ## List parent folder of your fintech path (helps discover children)
	@PARENT="$${PARENT:-secret/danipa/fintech}"; \
	echo "→ Listing parent: $$PARENT"; \
	$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  P="'"$$PARENT"'"; \
	  case "$$P" in secret|secret/) TARGET="secret/";; secret/*) TARGET="secret/$${P#secret/}";; *) echo "!! must start with secret"; exit 2;; esac; \
	  vault kv list "$$TARGET"'

# ---- Normalization helper (Bash snippet) ----
define _normalize_secret_path
  P="$$1"; \
  case "$$P" in \
    secret/data/*) echo "!! SECRET_PATH should NOT include 'secret/data/...'. Use 'secret/...'. Given: $$P" >&2; exit 2;; \
    secret/*)      TARGET="secret/$${P#secret/}";; \
    *)             echo "!! SECRET_PATH must start with 'secret/'. Given: $$P" >&2; exit 2;; \
  esac; \
  echo "$$TARGET"
endef

# --- Safer vault-put ---
vault-put: ## Write a test secret: make vault-put SECRET_PATH=secret/danipa/fintech/dev/demo K=foo V=bar
	@SECRET_PATH="$${SECRET_PATH:-secret/danipa/fintech/dev/demo}"; \
	K="$${K:-foo}"; V="$${V:-bar}"; \
	TARGET="$$( \
	  $(VAULT_CMD) '$(call _normalize_secret_path,$$SECRET_PATH)' \
	)"; \
	echo "→ Writing ($$K=$$V) to $$TARGET"; \
	$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  vault kv put "'"$$TARGET"'" "'"$$K"'"="'"$$V"'"'

# --- Safer vault-del (soft delete current version) ---
vault-del: ## Soft-delete a versioned entry: make vault-del SECRET_PATH=secret/danipa/fintech/dev/demo
	@SECRET_PATH="$${SECRET_PATH:-secret/danipa/fintech/dev/demo}"; \
	TARGET="$$( \
	  $(VAULT_CMD) '$(call _normalize_secret_path,$$SECRET_PATH)' \
	)"; \
	echo "→ Deleting $$TARGET (soft)"; \
	$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  vault kv delete "'"$$TARGET"'"'

# --- Hard purge: remove all versions + metadata ---
vault-purge: ## HARD delete metadata+versions: make vault-purge SECRET_PATH=secret/danipa/fintech/dev/demo
	@SECRET_PATH="$${SECRET_PATH:-secret/danipa/fintech/dev/demo}"; \
	TARGET="$$( \
	  $(VAULT_CMD) '$(call _normalize_secret_path,$$SECRET_PATH)' \
	)"; \
	echo "⚠ Purging ALL versions + metadata at $$TARGET"; \
	$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  vault kv metadata delete "'"$$TARGET"'"'

##@ Inspection / Browse

# Safer defaults (avoid clobbering shell PATH)
VAULT_KV_LIST_PATH ?= secret/danipa/fintech
VAULT_KV_GET_PATH  ?= secret/danipa/fintech/dev/demo

.PHONY: vault-env vault-ls vault-read vault-read-json vault-read-json-raw vault-token vault-whoami vault-cli

vault-env: ## Show the exact env & command used for vault ops (debug)
	@echo "VAULT_ADDR=$(VAULT_ADDR)"
	@echo "VAULT_CACERT=/vault/tls/root_ca.crt"
	@echo "Container: $(VAULT_CONT)"
	@echo "Try: docker exec -it $(VAULT_CONT) sh"

vault-ls: ## List keys under SECRET_PATH (KV v2). Usage: make vault-ls SECRET_PATH=secret/danipa/fintech
	@SECRET_PATH="$${SECRET_PATH:-$(VAULT_KV_LIST_PATH)}"; \
	echo "→ Listing: $$SECRET_PATH"; \
	$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  P="'"$$SECRET_PATH"'"; \
	  case "$$P" in secret|secret/) TARGET="secret/";; secret/*) TARGET="secret/$${P#secret/}";; *) echo "!! must start with secret"; exit 2;; esac; \
	  vault kv list "$$TARGET"'

vault-read: ## Read a secret (table). Usage: make vault-read SECRET_PATH=secret/danipa/fintech/dev/demo
	@SECRET_PATH="$${SECRET_PATH:-$(VAULT_KV_GET_PATH)}"; \
	test -n "$$SECRET_PATH" || { echo "Usage: make vault-read SECRET_PATH=secret/<path>"; exit 2; }; \
	echo "→ Reading: $$SECRET_PATH"; \
	$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  P="'"$$SECRET_PATH"'"; \
	  case "$$P" in secret/*) TARGET="secret/$${P#secret/}";; *) echo "!! SECRET_PATH must start with secret"; exit 2;; esac; \
	  vault kv get "$$TARGET"'

vault-read-json: ## Read a secret (.data pretty JSON). Usage: make vault-read-json SECRET_PATH=secret/danipa/fintech/dev/demo
	@SECRET_PATH="$${SECRET_PATH:-$(VAULT_KV_GET_PATH)}"; \
	test -n "$$SECRET_PATH" || { echo "Usage: make vault-read-json SECRET_PATH=secret/<path>"; exit 2; }; \
	echo "→ Reading (json): $$SECRET_PATH"; \
	OUT=$$( \
	  $(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	    P="'"$$SECRET_PATH"'"; \
	    case "$$P" in secret/*) TARGET="secret/$${P#secret/}";; *) echo "!! SECRET_PATH must start with secret"; exit 2;; esac; \
	    vault kv get -format=json "$$TARGET"' \
	); \
	( echo "$$OUT" | jq .data.data ) 2>/dev/null \
	|| python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get("data",{}).get("data",{}), indent=2))' <<<"$$OUT"

# Optional: add a helper to dump the full raw JSON (no filtering).
vault-read-json-raw: ## Raw JSON of a secret. Usage: make vault-read-json-raw SECRET_PATH=secret/...
	@SECRET_PATH="$${SECRET_PATH:-$(VAULT_KV_GET_PATH)}"; \
	test -n "$$SECRET_PATH" || { echo "Usage: make vault-read-json-raw SECRET_PATH=secret/<path>"; exit 2; }; \
	echo "→ Reading (raw json): $$SECRET_PATH"; \
	$(VAULT_CMD) 'export VAULT_ADDR="$(VAULT_ADDR)"; export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  P="'"$$SECRET_PATH"'"; \
	  case "$$P" in secret/*) TARGET="secret/$${P#secret/}";; *) echo "!! SECRET_PATH must start with secret"; exit 2;; esac; \
	  vault kv get -format=json "$$TARGET"' \
	| ( jq . 2>/dev/null || cat )

vault-token: ## Show token in Vault container (first 16 chars)
	@docker exec -i $(VAULT_CONT) sh -lc 't=$$(cat /root/.vault-token 2>/dev/null || true); \
	  if [ -n "$$t" ]; then echo "→ token: $${t:0:16}..."; else echo "No token at /root/.vault-token"; fi'

vault-cli: ## Interactive shell in the Vault container with VAULT_* preset
	@docker exec -it $(VAULT_CONT) sh -lc 'export VAULT_ADDR="$(VAULT_ADDR)"; \
	  export VAULT_CACERT="/vault/tls/root_ca.crt"; \
	  echo "VAULT_ADDR=$$VAULT_ADDR"; echo "VAULT_CACERT=$$VAULT_CACERT"; \
	  exec sh'

##@ Boostrap (Keycloak & Vault)
.PHONY: vault-bootstrap
vault-bootstrap: ## Alias: bootstrap Keycloak+Vault (delegates to core)
	@$(MAKE) bootstrap-keycloak-vault

endif
