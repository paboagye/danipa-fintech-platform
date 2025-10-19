# ---- Makefile.core.mk ----
ifndef CORE_MK_LOADED
CORE_MK_LOADED := 1

# -------------------------------
# Shared defaults (override via env/CLI)
# -------------------------------
NET     ?= danipa-net
COMPOSE ?= docker compose

# Pretty JSON if available; otherwise just pass-through
JQ ?= $(shell command -v jq >/dev/null 2>&1 && echo jq || echo cat)

# Actuator auth (modules can reuse)
ACT_USER ?= act
ACT_PASS ?= act-pass
ACT_CURL  = curl -sS -u $(ACT_USER):$(ACT_PASS)

# CRLF hygiene for Windows/WSL (use: $(call strip_crlf,$(VAR)))
CR := $(shell printf '\r')
strip_crlf = $(strip $(subst $(CR),,$(1)))

# -------------------------------
# Common helpers (macros & targets)
# -------------------------------
# Header banner
define hdr
@echo -e "\n=== $(1) ===\n"
endef

# Curl defaults used by health/waiters
CURL_SILENT ?= -fsS --connect-timeout 3 --max-time 5

# Wait until /actuator/health returns 2xx/3xx
# Usage: $(call wait_http,http://config-server:8088)
define wait_http
@echo ">> Waiting for $(1)/actuator/health ..."
@i=0; \
until curl $(CURL_SILENT) -o /dev/null -w '%{http_code}\n' "$(1)/actuator/health" | \
  grep -Eq '^(2|3)'; do \
  i=$$((i+1)); \
  if [ $$i -gt 60 ]; then echo "!! Timeout: $(1) not healthy"; exit 1; fi; \
  sleep 2; \
done; \
echo "✓ Healthy: $(1)"
endef

# Ensure a compose service key exists before using it
# Usage in a recipe:
#   $(call ensure_service,$(CONFIG_SERVICE))
ensure_service = @svcs="$$($(COMPOSE) config --services)"; \
  svc="$(call strip_crlf,$(1))"; \
  echo "$$svcs" | grep -qx "$$svc" || { \
    echo "ERROR: compose service '$$svc' not found."; \
    echo "Detected services:"; echo "$$svcs" | sed 's/^/  - /'; \
    exit 2; \
  }

# -------------------------------
# Unified help (aggregates from all includes)
# -------------------------------
.PHONY: help
help:
	@awk 'BEGIN {FS=":.*##"; printf "\nDanipa Fintech Platform - Makefile\n\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	/^[a-zA-Z0-9_\-]+:.*##/ { printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2 } \
	/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0,5) } ' $(MAKEFILE_LIST)

endif
