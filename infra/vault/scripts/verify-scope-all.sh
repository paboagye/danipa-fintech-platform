### === Scope verification helpers ===
# Usage:
#   make verify-scope CID=eureka-server SEC=xxxx
#   make verify-scope CID=eureka-server SEC=xxxx SCOPE=config.read
#   make verify-scope-all ENV=dev SCOPE=config.read         # loops callers, pulls secrets from seeds or env
#
# Requires: curl, jq, base64

REALM ?= danipa
KC    ?= http://localhost:8082
ENV   ?= dev
SEEDS ?= infra/vault/seeds/$(ENV).json
CALLERS ?= eureka-server danipa-fintech-service

.PHONY: verify-scope
verify-scope:
	@if [ -z "$(CID)" ]; then echo "CID=<clientId> is required"; exit 2; fi
	@if [ -z "$(SEC)" ]; then echo "SEC=<clientSecret> is required"; exit 2; fi
	@echo "== Minting token for $(CID) (scope=none) =="
	@RAW=$$(curl -s -X POST "$(KC)/realms/$(REALM)/protocol/openid-connect/token" \
		-H 'Content-Type: application/x-www-form-urlencoded' \
		-d grant_type=client_credentials -d client_id="$(CID)" -d client_secret="$(SEC)"); \
	TOK=$$(echo $$RAW | jq -r '.access_token // empty'); \
	if [ -z "$$TOK" ]; then echo "$$RAW" | jq .; exit 1; fi; \
	echo "--- decoded token ---"; \
	echo $$TOK | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null \
	| jq '{azp, aud, scope, roles: .realm_access.roles}'
	@if [ -n "$(SCOPE)" ]; then \
		echo "== Minting token for $(CID) (scope=$(SCOPE)) =="; \
		RAW=$$(curl -s -X POST "$(KC)/realms/$(REALM)/protocol/openid-connect/token" \
			-H 'Content-Type: application/x-www-form-urlencoded' \
			-d grant_type=client_credentials -d client_id="$(CID)" -d client_secret="$(SEC)" \
			-d scope="$(SCOPE)"); \
		TOK=$$(echo $$RAW | jq -r '.access_token // empty'); \
		if [ -z "$$TOK" ]; then echo "$$RAW" | jq .; exit 1; fi; \
		echo "--- decoded token ---"; \
		echo $$TOK | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null \
		| jq '{azp, aud, scope, roles: .realm_access.roles}'; \
	fi

# Helper: pull a client secret for $(1) from env if set, else from $(SEEDS)
# Recognizes env vars EUREKA_SERVER_CLIENT_SECRET and DANIPA_FINTECH_SERVICE_CLIENT_SECRET
define GET_SECRET_SH
sec=""; c="$(1)"; \
case "$$c" in \
  eureka-server)          sec="$${EUREKA_SERVER_CLIENT_SECRET:-}";; \
  danipa-fintech-service) sec="$${DANIPA_FINTECH_SERVICE_CLIENT_SECRET:-}";; \
esac; \
if [ -z "$$sec" ] && [ -f "$(SEEDS)" ]; then \
  sec="$$(jq -r --arg c "$$c" --arg e "$(ENV)" '.paths[$$c, $$e].SPRING_CLOUD_CONFIG_CLIENT_OAUTH2_CLIENT_SECRET // empty' "$(SEEDS)")"; \
fi; \
printf "%s" "$$sec"
endef

.PHONY: verify-scope-all
verify-scope-all:
	@for c in $(CALLERS); do \
	  sec="$$(sh -c '$(GET_SECRET_SH)' )"; \
	  if [ -z "$$sec" ]; then echo "!! Missing secret for $$c (set env or ensure $(SEEDS) has it)"; exit 2; fi; \
	  echo ""; echo "### $$c ###"; \
	  $(MAKE) -s verify-scope CID="$$c" SEC="$$sec" SCOPE="$(SCOPE)"; \
	done
