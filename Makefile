# ---------------------------
# Vault TLS certificate flow
# ---------------------------

# Default CN and SANs (can be overridden at CLI)
CN ?= vault.local.danipa.com
SANS ?= vault.local.danipa.com vault localhost 127.0.0.1

VAULT_CERT_SCRIPT = vault_cert.sh
TLS_DIR = ../../tls

.PHONY: vault-cert
vault-cert:  ## Issue a new Vault TLS cert/key via step-ca and reload Vault
	@echo ">> Issuing Vault cert for CN=$(CN) with SANs: $(SANS)"
	SANS="$(SANS)" $(VAULT_CERT_SCRIPT) issue "$(CN)"

	@echo ">> Restarting Vault container to pick up new certs..."
	docker compose up -d --no-deps --force-recreate vault

	@echo ">> Checking Vault health via TLS..."
	curl -sS --cacert $(TLS_DIR)/root_ca.crt \
	  --resolve $(CN):18300:127.0.0.1 \
	  https://$(CN):18300/v1/sys/health | jq

.PHONY: vault-unseal
vault-unseal:  ## Unseal Vault manually (expects UNSEAL_KEY set in env)
	@if [ -z "$$UNSEAL_KEY" ]; then \
		echo "ERROR: Please export UNSEAL_KEY=<your_unseal_key>"; exit 1; \
	fi
	@echo ">> Unsealing Vault with provided key..."
	docker exec danipa-vault sh -lc \
	  'vault operator unseal -address=https://127.0.0.1:8200 -tls-skip-verify "$$UNSEAL_KEY"'
