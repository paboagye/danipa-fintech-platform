#!/usr/bin/env bash
set -euo pipefail

env_name="${1:-dev}"

# Optional: ENV_FILE to pre-load creds for config server auth, etc.
if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8300}"
CONFIG_HEALTH_URL="${CONFIG_HEALTH_URL:-http://127.0.0.1:8088/actuator/health}"
EUREKA_HEALTH_URL="${EUREKA_HEALTH_URL:-http://127.0.0.1:8761/actuator/health}"
FINTECH_HEALTH_URL="${FINTECH_HEALTH_URL:-http://127.0.0.1:8080/api/actuator/health}"

pass() { echo "✅ $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

# 1) Vault health
if curl -fsS "${VAULT_ADDR}/v1/sys/health" >/dev/null; then pass "Vault health OK"; else fail "Vault health FAILED"; fi

# 2) Read a KV doc
if curl -fsS "${VAULT_ADDR}/v1/secret/data/danipa/fintech/${env_name}" | jq -e .data.data >/dev/null; then
  pass "Vault KV read: secret/danipa/fintech/${env_name}"
else
  fail "Vault KV read FAILED (secret/danipa/fintech/${env_name})"
fi

# 3) Config Server health (basic auth optional)
if [[ -n "${CONFIG_USER:-}" && -n "${CONFIG_PASS:-}" ]]; then
  if curl -fsS -u "${CONFIG_USER}:${CONFIG_PASS}" "${CONFIG_HEALTH_URL}" | grep -q '"status":"UP"'; then pass "Config Server UP"; else fail "Config Server DOWN"; fi
else
  if curl -fsS "${CONFIG_HEALTH_URL}" | grep -q '"status":"UP"'; then pass "Config Server UP"; else fail "Config Server DOWN"; fi
fi

# 4) Eureka health
if curl -fsS "${EUREKA_HEALTH_URL}" | grep -q '"status":"UP"'; then pass "Eureka UP"; else fail "Eureka DOWN"; fi

# 5) Fintech health
if curl -fsS "${FINTECH_HEALTH_URL}" | grep -q '"status":"UP"'; then pass "Fintech Service UP"; else fail "Fintech Service DOWN"; fi
