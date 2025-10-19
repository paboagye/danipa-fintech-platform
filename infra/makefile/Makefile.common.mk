# --- infra/makefile/Makefile.common.mk ---

# CRLF guard (Windows/WSL safety)
CR := $(shell printf '\r')

# ==== Actuator auth defaults (override per env) ====
ACT_USER ?= act
ACT_PASS ?= act-pass

# ==== TLS / curl flags shared by all ====
ACT_INSECURE   ?= 1
CURL_INT_FLAGS :=
CURL_EXT_FLAGS := --fail-with-body
ifeq ($(ACT_INSECURE),1)
  CURL_INT_FLAGS += -k
  CURL_EXT_FLAGS += -k
endif
ifdef USE_CUSTOM_CA
  VAULT_CACERT  ?= infra/vault/tls/root_ca.crt
  CURL_EXT_FLAGS += --cacert "$(VAULT_CACERT)"
endif
ifdef CURL_FORCE_RESOLVE
  # e.g. 'host.example:443:127.0.0.1'
  CURL_EXT_FLAGS += --resolve $(CURL_FORCE_RESOLVE)
endif

# ======== Shared Git metadata ========
# Use shell fallback if not in a Git repo (e.g., CI tarball)
GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo local)
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

export GIT_BRANCH
export GIT_COMMIT

# ==== wait_http macro (no jq dependency) ====
# Probes $1/actuator/health until "status":"UP" appears or times out.
# Usage: $(call wait_http,https://host:port[/base-path])
define wait_http
	@echo "-> Waiting for $1 ..."
	@bash -lc '\
	  url="$1"; for i in $$(seq 1 60); do \
	    body="$$(curl -sS $(CURL_EXT_FLAGS) -u $(ACT_USER):$(ACT_PASS) "$$url/actuator/health" || true)"; \
	    if printf "%s" "$$body" | grep -qiE "\"status\"[[:space:]]*:[[:space:]]*\"UP\""; then \
	      echo "   ✓ Healthy: $$url"; exit 0; \
	    fi; sleep 1; \
	  done; echo "ERROR: not healthy: $$url" >&2; exit 1'
endef

# Compute git in a specific directory (submodule-safe).
# $(1) = PATH_TO_REPO (e.g., danipa-eureka-server)
# $(2) = COMPOSE_SERVICE (e.g., eureka-server)
define build_with_git
	@BRANCH=$$(git -C $(1) rev-parse --abbrev-ref HEAD 2>/dev/null || echo local); \
	COMMIT=$$(git -C $(1) rev-parse --short HEAD 2>/dev/null || echo dev); \
	echo ">> Building $(2) :: $$BRANCH @ $$COMMIT"; \
	docker compose build \
	  --build-arg GIT_BRANCH="$$BRANCH" \
	  --build-arg GIT_COMMIT="$$COMMIT" \
	  $(2)
endef

# Optional: wrapper that also prints the effective Docker build args
define show_git
	@echo ">> $(1) git: BRANCH=$$(git -C $(1) rev-parse --abbrev-ref HEAD 2>/dev/null || echo local) \
 COMMIT=$$(git -C $(1) rev-parse --short HEAD 2>/dev/null || echo dev)"
endef

# NOTE:
# Do NOT define a `help` target here to avoid overriding the one in Makefile.core.mk.
