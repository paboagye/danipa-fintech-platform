#!/usr/bin/env bash
# vault-kv-list.sh
# Recursively list KV v2 secret paths and (optionally) show values.
# Dependencies: curl, jq
set -euo pipefail

# ---------- Defaults ----------
VAULT_URI="http://127.0.0.1:18300"
MOUNT="secret"     # KV v2 mount name
BASE=""            # start path; "" = root
SHOW_VALUES="false"
TOKEN="${TOKEN:-}" # allow env override

# ---------- Args ----------
usage() {
  cat <<EOF
Usage: $(basename "$0") [--vault-uri URL] [--token TOKEN] [--mount NAME] [--base PATH] [--show-values]

Options:
  --vault-uri      Vault address (default: $VAULT_URI)
  --token          Vault token (default: auto from infra/vault/keys/vault-keys.json)
  --mount          KV v2 mount name (default: $MOUNT)
  --base           Start prefix (default: empty = root)
  --show-values    Also print key=value pairs for each secret
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-uri)   VAULT_URI="${2:-}"; shift 2 ;;
    --token)       TOKEN="${2:-}";     shift 2 ;;
    --mount)       MOUNT="${2:-}";     shift 2 ;;
    --base)        BASE="${2:-}";      shift 2 ;;
    --show-values) SHOW_VALUES="true"; shift 1 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

# ---------- Dependency checks ----------
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required." >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "ERROR: jq is required."   >&2; exit 1; }

# ---------- Token auto-load (only if not provided) ----------
if [[ -z "${TOKEN:-}" ]]; then
  # First try repo-root relative path as requested
  if [[ -f "infra/vault/keys/vault-keys.json" ]]; then
    TOKEN="$(jq -r .root_token infra/vault/keys/vault-keys.json)"
  else
    # Also try relative to this script if it's placed under infra/vault/scripts/
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    if [[ -f "$SCRIPT_DIR/../keys/vault-keys.json" ]]; then
      TOKEN="$(jq -r .root_token "$SCRIPT_DIR/../keys/vault-keys.json")"
    else
      echo "ERROR: No TOKEN provided and vault-keys.json not found at:" >&2
      echo "  - infra/vault/keys/vault-keys.json (from current dir)" >&2
      echo "  - \$SCRIPT_DIR/../keys/vault-keys.json (next to this script)" >&2
      exit 1
    fi
  fi
fi

# ---------- Helpers ----------
trim_slashes() {
  local s="${1:-}"
  s="${s#/}"; s="${s%/}"
  printf '%s' "$s"
}

http_get() {
  # $1 = URL
  curl -sS --fail -H "X-Vault-Token: $TOKEN" "$1"
}

http_list() {
  # Emulate LIST using X-HTTP-Method-Override on GET
  # $1 = URL
  curl -sS --fail \
    -H "X-Vault-Token: $TOKEN" \
    -H "X-HTTP-Method-Override: LIST" \
    "$1"
}

get_health() {
  # returns HTTP code only (body not required)
  curl -sS -o /dev/null -w '%{http_code}' "$VAULT_URI/v1/sys/health" || echo "000"
}

list_kv_metadata() {
  # Recursively list all metadata paths under prefix
  # $1 = prefix ('' for root or 'a/b')
  local p uri resp keys key child
  p="$(trim_slashes "${1:-}")"

  if [[ -z "$p" ]]; then
    uri="$VAULT_URI/v1/$MOUNT/metadata?list=true"
  else
    uri="$VAULT_URI/v1/$MOUNT/metadata/$p?list=true"
  fi

  if ! resp="$(http_list "$uri" 2>/dev/null || true)"; then
    return
  fi

  keys="$(jq -r 'try .data.keys[]' <<<"$resp" 2>/dev/null || true)"
  [[ -z "$keys" ]] && return

  while IFS= read -r key; do
    if [[ "$key" == */ ]]; then
      key="${key%/}"
      if [[ -z "$p" ]]; then child="$key"; else child="$p/$key"; fi
      list_kv_metadata "$child"
    else
      if [[ -z "$p" ]]; then echo "$key"; else echo "$p/$key"; fi
    fi
  done <<<"$keys"
}

read_kv_data() {
  # $1 = data path (no leading slash)
  local path uri
  path="$(trim_slashes "$1")"
  uri="$VAULT_URI/v1/$MOUNT/data/$path"
  http_get "$uri" | jq -r 'try .data.data // empty'
}

# ---------- Main ----------
echo "==> Checking Vault health at $VAULT_URI"
code="$(get_health)"
if [[ "$code" == "503" ]]; then
  echo "WARNING: Vault is SEALED (503). Unseal and re-run." >&2
  exit 1
elif [[ "$code" == "501" ]]; then
  echo "WARNING: Vault NOT INITIALIZED (501)." >&2
  exit 1
elif [[ "$code" == "000" || "$code" -lt 200 || "$code" -ge 400 ]]; then
  echo "WARNING: Vault unavailable (status: $code)." >&2
  exit 1
fi

echo "==> Listing KV v2 paths under '$MOUNT' (base='${BASE}') at $VAULT_URI"
echo

mapfile -t PATHS < <(list_kv_metadata "$BASE" | sort || true)

if [[ "${#PATHS[@]}" -eq 0 ]]; then
  echo "(no secrets found under $MOUNT/metadata/${BASE})"
  exit 0
fi

printf "%-46s  %s\n" "PATH" "KEYS"
printf "%-46s  %s\n" "----------------------------------------------" "----------------------------------------"

for p in "${PATHS[@]}"; do
  if ! data_json="$(read_kv_data "$p" 2>/dev/null || true)"; then
    printf "%-46s  %s\n" "$p" "(read failed)"
    continue
  fi

  keys_csv="$(jq -r 'if .=={} then "" else (keys | join(", ")) end' <<<"$data_json")"
  printf "%-46s  %s\n" "$p" "${keys_csv}"

  if [[ "$SHOW_VALUES" == "true" && -n "$keys_csv" ]]; then
    jq -r 'to_entries[] | "    \(.key) = \(.value)"' <<<"$data_json"
  fi
done
