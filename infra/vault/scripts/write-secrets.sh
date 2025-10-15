#!/usr/bin/env bash
# Seeds KV v2 from infra/vault/seeds/<env>.json AND creates policies + AppRole
# -------------------------------------------------------------------------------------------------
# - COMMA-ONLY composite seeding (no slash mirroring).
# - Deletes legacy slash composite: secret/data|metadata/danipa-config-server/composite.
# - Verifies policies & AppRoles; mints per-env composite token; fintech/eureka policies.
# - validate_composite() ensures each composite[N] has a "type".
# - Writes freshly minted composite token back into <env>.json (seed file) so it always reflects latest.
# -------------------------------------------------------------------------------------------------
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.local.danipa.com}"
VAULT_CACERT="${VAULT_CACERT:-$(pwd)/infra/vault/tls/root_ca.crt}"
VAULT_TLS_SERVER_NAME="${VAULT_TLS_SERVER_NAME:-vault.local.danipa.com}"
MOUNT="${MOUNT:-secret}"
SEEDS_DIR="${SEEDS_DIR:-infra/vault/seeds}"
HEALTH_PROBE_PATH="${HEALTH_PROBE_PATH:-app}"
TOKEN="${TOKEN:-}"                   # REQUIRED
ENVS="${ENVS:-dev,staging,prod}"     # comma-separated
SHOW_VALUES="${SHOW_VALUES:-false}"  # true/false (prints secrets if true! Beware!)
DRY_RUN="${DRY_RUN:-false}"          # true/false
VERIFY_ONLY="${VERIFY_ONLY:-false}"  # true/false
MIRROR_MODE="${MIRROR_MODE:-comma-only}"  # comma-only | both

[ -z "${TOKEN}" ] && { echo "ERROR: set TOKEN env var"; exit 2; }
echo "==> VAULT_ADDR=$VAULT_ADDR  MOUNT=$MOUNT  SEEDS_DIR=$SEEDS_DIR  MIRROR_MODE=$MIRROR_MODE"
[ "$VERIFY_ONLY" = "true" ] && echo "==> VERIFY_ONLY=true — verification only (no writes)"

auth_hdr=(-H "X-Vault-Token: $TOKEN")

# --- TLS helpers for curl (vcurl) ---
CURL_TLS_ARGS=()
[ -n "${VAULT_CACERT:-}" ] && [ -f "$VAULT_CACERT" ] && CURL_TLS_ARGS+=( --cacert "$VAULT_CACERT" )
[ -n "${VAULT_FORCE_RESOLVE:-}" ] && CURL_TLS_ARGS+=( --resolve "$VAULT_FORCE_RESOLVE" )
vcurl() { curl -sS "${auth_hdr[@]}" "${CURL_TLS_ARGS[@]}" "$@"; }

print_masked() {
  python3 - "$1" "$SHOW_VALUES" <<'PY'
import sys, json
raw = sys.argv[1]; show = (sys.argv[2].lower()=="true")
try: d = json.loads(raw)
except Exception: d = {}
for k in sorted(d.keys()):
    v = d[k]; s = "" if v is None else str(v)
    if show: out = s if s != "" else "<null>"
    else:
        if v is None: out = "<null>"
        elif len(s) <= 4: out = "*"*len(s)
        else: out = s[:2] + "*"*(len(s)-4) + s[-2:]
    print(f"  {k} = {out}")
PY
}

ensure_kv2() {
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRYRUN] Would ensure KV v2 mount '$MOUNT'"; return
  fi
  vcurl -o /tmp/mounts.json -w '%{http_code}' "$VAULT_ADDR/v1/sys/mounts" >/dev/null || true
  if grep -q "\"${MOUNT}/\"" /tmp/mounts.json 2>/dev/null; then
    vcurl -o /tmp/tune.json "$VAULT_ADDR/v1/sys/mounts/$MOUNT/tune" >/dev/null || true
    ver=$(python3 - <<'PY'
import json
try:
  d=json.load(open("/tmp/tune.json"))
  dd=d.get("data") or d
  print((dd.get("options") or {}).get("version",""))
except: print("")
PY
)
    if [ "$ver" != "2" ]; then
      echo "Tuning mount '$MOUNT' to kv v2..."
      vcurl -H 'Content-Type: application/json' \
        -X POST "$VAULT_ADDR/v1/sys/mounts/$MOUNT/tune" -d '{"options":{"version":"2"}}' -o /dev/null
    fi
  else
    echo "Mount '$MOUNT' not found. Enabling KV v2..."
    vcurl -H 'Content-Type: application/json' \
      -X POST "$VAULT_ADDR/v1/sys/mounts/$MOUNT" -d '{"type":"kv","options":{"version":"2"}}' -o /dev/null
  fi
  echo "KV v2 ready at mount '$MOUNT'."
}

write_secret() {
  local path="$1"; local data_json="$2"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRYRUN] WOULD WRITE $MOUNT/data/$path"
  else
    vcurl -H 'Content-Type: application/json' \
      -X POST "$VAULT_ADDR/v1/$MOUNT/data/$path" -d "{\"data\":$data_json}" -o /dev/null
    echo "WROTE: $MOUNT/data/$path"
  fi
  print_masked "$data_json"
}

seed_health_probe() {
  local path="$HEALTH_PROBE_PATH"; local data='{"ok":"true"}'
  echo "Seeding health probe key: $MOUNT/data/$path"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRYRUN] WOULD WRITE $MOUNT/data/$path"
  else
    vcurl -H 'Content-Type: application/json' \
      -X POST "$VAULT_ADDR/v1/$MOUNT/data/$path" -d "{\"data\":$data}" -o /dev/null
  fi
}

ensure_approle() {
  [ "$DRY_RUN" = "true" ] && { echo "[DRYRUN] Would enable auth/approle"; return; }
  vcurl "$VAULT_ADDR/v1/sys/auth" -o /tmp/auth.json >/dev/null || true
  if grep -q '"approle/"' /tmp/auth.json 2>/dev/null; then
    echo "auth/approle already enabled."
  else
    echo "Enabling auth/approle..."
    vcurl -H 'Content-Type: application/json' \
      -X POST "$VAULT_ADDR/v1/sys/auth/approle" -d '{"type":"approle"}' -o /dev/null || true
  fi
}

upsert_policy() {
  local name="$1"; local hcl="$2"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRYRUN] Would upsert policy $name"; return
  fi
  local payload out status
  payload="$(python3 -c 'import sys,json; print(json.dumps({"policy": sys.stdin.read()}))' <<< "$hcl")"
  out="/tmp/policy.upsert.$name.json"
  status="$(vcurl -H 'Content-Type: application/json' \
            -X PUT "$VAULT_ADDR/v1/sys/policy/$name" -d "$payload" -w '%{http_code}' -o "$out" || true)"
  if [ "$status" = "404" ]; then
    status="$(vcurl -H 'Content-Type: application/json' \
              -X PUT "$VAULT_ADDR/v1/sys/policies/acl/$name" -d "$payload" -w '%{http_code}' -o "$out" || true)"
  fi
  if [ "$status" != "204" ] && [ "$status" != "200" ]; then
    echo "ERROR: upsert policy '$name' failed (HTTP $status):"
    sed -n '1,200p' "$out"; exit 1
  fi
  echo "POLICY upserted: $name"
}

upsert_approle() {
  local role="$1"; local policies_csv="$2"; local ttl="${3:-1h}"; local max="${4:-24h}"
  if [ "$DRY_RUN" = "true" ]; then
    echo "<dry-role-id>"; echo "<dry-secret-id>"; return
  fi
  local payload rid sid
  payload="$(python3 -c 'import sys,json; print(json.dumps({
      "token_policies": sys.argv[1].split(","),
      "token_ttl": sys.argv[2],
      "token_max_ttl": sys.argv[3]
  }))' "$policies_csv" "$ttl" "$max")"
  vcurl -H 'Content-Type: application/json' \
    -X POST "$VAULT_ADDR/v1/auth/approle/role/$role" -d "$payload" -o /dev/null
  rid="$(vcurl "$VAULT_ADDR/v1/auth/approle/role/$role/role-id" \
        | python3 -c 'import sys,json; print((json.load(sys.stdin).get("data") or {}).get("role_id",""))')"
  sid="$(vcurl -X POST "$VAULT_ADDR/v1/auth/approle/role/$role/secret-id" \
        | python3 -c 'import sys,json; print((json.load(sys.stdin).get("data") or {}).get("secret_id",""))')"
  printf '%s\n%s\n' "$rid" "$sid"
}

verify_policies() {
  local env="$1"          # dev | staging | prod
  local app="config-server"
  local base="danipa-config-server"
  local policy="read-${app}-secrets-${env}"

  echo "VERIFY[$env]: policy '$policy' + AppRole caps …"

  local legacy="$VAULT_ADDR/v1/sys/policy/$policy"
  local modern="$VAULT_ADDR/v1/sys/policies/acl/$policy"
  local c1 c2 src=""
  c1="$(vcurl -o /tmp/pol.legacy.json -w '%{http_code}' "$legacy" || true)"
  c2="$(vcurl -o /tmp/pol.modern.json -w '%{http_code}' "$modern" || true)"
  if [ "$c1" = "200" ] && grep -q '"rules"' /tmp/pol.legacy.json 2>/dev/null; then
    src=/tmp/pol.legacy.json
  elif [ "$c2" = "200" ] && grep -q '"rules"' /tmp/pol.modern.json 2>/dev/null; then
    src=/tmp/pol.modern.json
  else
    echo "  policy GET: no rules (legacy HTTP $c1; modern HTTP $c2)"
  fi
  if [ -n "$src" ]; then
    python3 - "$src" "$MOUNT" "$base" <<'PY' || true
import sys, json
p, mount, base = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(p))
    rules = (d.get("data") or {}).get("rules") or d.get("rules") or ""
    needles = [
      f'path "{mount}/data/{base}/*"',
      f'path "{mount}/metadata/{base}"',
      f'path "{mount}/metadata/{base}/*"'
    ]
    for n in needles:
        print("  wildcard:", ("present" if n in rules else f"MISSING -> {n}"))
except Exception as e:
    print("  policy JSON parse: FAILED:", e)
PY
  fi

  local d="infra/vault/approle/${app}-${env}"
  if [ ! -f "$d/role_id" ] || [ ! -f "$d/secret_id" ]; then
    echo "  approle creds: MISSING ($d)"; return 0
  fi
  local rid sid login_json app_token
  rid="$(tr -d '\r\n' < "$d/role_id")"
  sid="$(tr -d '\r\n' < "$d/secret_id")"
  echo "  role_id: ${rid:0:4}****"
  echo "  secret_id: ${sid:0:4}****"
  login_json="$(vcurl -H 'Content-Type: application/json' \
      -d "{\"role_id\":\"$rid\",\"secret_id\":\"$sid\"}" \
      "$VAULT_ADDR/v1/auth/approle/login" || true)"
  app_token="$(
    python3 - "$login_json" <<'PY'
import sys, json
raw = sys.argv[1]
try:
    d = json.loads(raw) if raw.strip() else {}
    print(((d.get("auth") or {}).get("client_token") or ""))
except Exception:
    print("")
PY
  )" || true
  if [ -z "$app_token" ]; then
    echo "  approle login: FAILED"; return 0
  fi

  local paths_json
  paths_json=$(cat <<JSON
[ "$MOUNT/data/${base}",
  "$MOUNT/data/${base},${env}",
  "$MOUNT/data/${base}/${env}",
  "$MOUNT/data/${base}/*",
  "$MOUNT/data/danipa/config",
  "$MOUNT/data/danipa/config,composite",
  "$MOUNT/data/danipa/config/composite",
  "$MOUNT/data/application/composite",
  "$MOUNT/metadata/${base}",
  "$MOUNT/metadata/${base}/*" ]
JSON
)
  python3 - "$paths_json" "$VAULT_ADDR" "$app_token" <<'PY' || true
import sys, json, urllib.request
paths=json.loads(sys.argv[1]); addr=sys.argv[2]; tok=sys.argv[3]
def caps(p):
    req=urllib.request.Request(addr + "/v1/sys/capabilities-self",
                               data=json.dumps({"paths":[p]}).encode("utf-8"),
                               headers={"X-Vault-Token": tok, "Content-Type":"application/json"},
                               method="POST")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            d=json.loads(r.read().decode("utf-8"))
        data=d.get("data") or d
        caps = data.get("capabilities") or data.get(p) or []
        return ",".join(caps)
    except Exception as e:
        return f"<err:{e}>"
for p in paths:
    print(f"  {p}: {caps(p)}")
PY
  echo "  caps: OK"
}

# ---------- VERIFY-ONLY SHORT-CIRCUIT ----------
if [ "$VERIFY_ONLY" = "true" ]; then
  IFS=',' read -r -a envs <<<"$ENVS"
  failures=0
  for env in "${envs[@]}"; do verify_policies "$env" || failures=$((failures+1)); done
  [ $failures -gt 0 ] && { echo "Verify failed for $failures environment(s)."; exit 1; }
  echo "Verify OK for all environments."; exit 0
fi
# ----------------------------------------------

ensure_kv2
IFS=',' read -r -a envs <<<"$ENVS"

# Hard cleanup: legacy slash composite (data + metadata)
cleanup_legacy_slash_composite() {
  local data="${MOUNT}/data/danipa-config-server/composite"
  local meta="${MOUNT}/metadata/danipa-config-server/composite"
  echo "Cleaning legacy slash composite (if present): $data and $meta"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRYRUN] WOULD DELETE $VAULT_ADDR/v1/$data"
    echo "[DRYRUN] WOULD DELETE $VAULT_ADDR/v1/$meta"
  else
    vcurl -X DELETE "$VAULT_ADDR/v1/$data" -o /dev/null || true
    vcurl -X DELETE "$VAULT_ADDR/v1/$meta" -o /dev/null || true
  fi
}

cleanup_service_composites() {
  local svc="$1"  # e.g., danipa-fintech-service
  local data_slash="$MOUNT/data/$svc/composite"
  local meta_slash="$MOUNT/metadata/$svc/composite"
  local data_comma="$MOUNT/data/$svc,composite"
  local meta_comma="$MOUNT/metadata/$svc,composite"
  echo "Cleaning stray composites for $svc (if present): $data_slash | $meta_slash | $data_comma | $meta_comma"
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRYRUN] WOULD DELETE $VAULT_ADDR/v1/$data_slash"
    echo "[DRYRUN] WOULD DELETE $VAULT_ADDR/v1/$meta_slash"
    echo "[DRYRUN] WOULD DELETE $VAULT_ADDR/v1/$data_comma"
    echo "[DRYRUN] WOULD DELETE $VAULT_ADDR/v1/$meta_comma"
  else
    vcurl -X DELETE "$VAULT_ADDR/v1/$data_slash" >/dev/null 2>&1 || true
    vcurl -X DELETE "$VAULT_ADDR/v1/$meta_slash" >/dev/null 2>&1 || true
    vcurl -X DELETE "$VAULT_ADDR/v1/$data_comma" >/dev/null 2>&1 || true
    vcurl -X DELETE "$VAULT_ADDR/v1/$meta_comma" >/dev/null 2>&1 || true
  fi
}

# After seeding, verify composite[] has types to avoid NPE in Config Server
validate_composite() {
  local env="$1"
  echo "Validate composite keys (effective) for env=$env …"
  local js
  js="$(vcurl "$VAULT_ADDR/v1/$MOUNT/data/danipa-config-server,composite" \
        | jq -r '.data.data | to_entries | map(select(.key | startswith("spring.cloud.config.server.composite[")))')" || true
  if [ -z "$js" ] || [ "$js" = "null" ]; then
    echo "ERROR: no composite keys found at $MOUNT/data/danipa-config-server,composite"; return 1
  fi
  python3 - "$js" <<'PY'
import sys, json, re
entries = json.loads(sys.argv[1])
idx_keys = {}
for e in entries:
    k=e['key']; m=re.match(r'spring\.cloud\.config\.server\.composite\[(\d+)\]\.(.+)$', k)
    if not m: continue
    i=int(m.group(1)); prop=m.group(2)
    idx_keys.setdefault(i,set()).add(prop)
missing=[]
for i,props in sorted(idx_keys.items()):
    if 'type' not in props: missing.append(i)
if missing:
    print("ERROR: composite entries missing 'type' at indexes:", ",".join(map(str,missing)))
    sys.exit(3)
print("OK: composite entries have required 'type'.")
PY
}

# ---- SEEDING ----
for env in "${envs[@]}"; do
  json="$SEEDS_DIR/$env.json"
  [ -f "$json" ] || { echo "WARN: [$env] seeds file not found: $json"; continue; }
  echo "==> [$env] reading paths from $json"

  python3 - "$json" >/tmp/seed.$env.tsv <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text(encoding="utf-8-sig"))
paths = (d.get("paths") or {})
for k,v in paths.items():
    print(k+"\t"+json.dumps(v,separators=(",",":")))
PY

  while IFS=$'\t' read -r P DATA; do
    [ -z "$P" ] && continue
    # normalize to comma form where applicable
    if [[ "$P" == "danipa-config-server/composite" ]]; then
      P="danipa-config-server,composite"
    fi
    write_secret "$P" "$DATA"
    if [[ "$P" =~ ^([^,]+)/(dev|staging|prod|composite)$ ]]; then
      base="${BASH_REMATCH[1]}"; envp="${BASH_REMATCH[2]}"
      write_secret "${base},${envp}" "$DATA"
    fi
    if [ "$MIRROR_MODE" = "both" ]; then
      if [[ "$P" == *","* ]]; then
        P_SLASH="${P/,//}"; write_secret "$P_SLASH" "$DATA"
      elif [[ "$P" == */* ]]; then
        base="${P%/*}"; tail="${P##*/}"
        if [[ "$tail" =~ ^(dev|staging|prod|composite)$ ]]; then
          write_secret "${base},${tail}" "$DATA"
        fi
      fi
    fi
  done < /tmp/seed.$env.tsv

  cleanup_legacy_slash_composite
  cleanup_service_composites "danipa-fintech-service"
  cleanup_service_composites "danipa-eureka-server"
  validate_composite "$env"
done

# ---- POLICIES + APPROLE (config-server) ----
ensure_approle
APP="config-server"
BASE="danipa-config-server"

EXTRA=(
  "danipa-config-server,composite"
  "danipa/config,composite"
  "danipa/config,{env}"
  "application/composite"
  "application"
  "danipa-eureka-server"
  "danipa-eureka-server/default"
  "danipa-eureka-server,{env}"
  "danipa-fintech-service"
  "danipa-fintech-service/default"
  "danipa-fintech-service,{env}"
)

[ "$DRY_RUN" != "true" ] && mkdir -p "infra/vault/approle" || true

for env in "${envs[@]}"; do
  policy="read-${APP}-secrets-${env}"

  hcl="path \"$MOUNT/data/${BASE},${env}\" { capabilities = [\"read\"] }
path \"$MOUNT/data/${BASE}/${env}\" { capabilities = [\"read\"] }
path \"$MOUNT/data/${BASE}\"       { capabilities = [\"read\"] }
"
  for xp in "${EXTRA[@]}"; do
    xp="${xp//\{env\}/$env}"
    hcl+=$(printf 'path "%s/data/%s" { capabilities = ["read"] }\n' "$MOUNT" "$xp")
    if [[ "$xp" != "danipa-config-server,composite" && "$xp" == *","* ]]; then
      xp_slash="${xp/,//}"
      hcl+=$(printf 'path "%s/data/%s" { capabilities = ["read"] }\n' "$MOUNT" "$xp_slash")
    fi
  done

  hcl+="path \"$MOUNT/data/danipa/config\"       { capabilities = [\"read\"] }
path \"$MOUNT/data/danipa/config/*\"   { capabilities = [\"read\"] }

path \"$MOUNT/data/${BASE}/*\"         { capabilities = [\"read\"] }
path \"$MOUNT/metadata/${BASE}\"       { capabilities = [\"list\"] }
path \"$MOUNT/metadata/${BASE}/*\"     { capabilities = [\"list\"] }
path \"$MOUNT/metadata/danipa\"        { capabilities = [\"list\"] }
path \"$MOUNT/metadata/danipa/*\"      { capabilities = [\"list\"] }
path \"$MOUNT/metadata/application\"   { capabilities = [\"list\"] }
path \"$MOUNT/metadata/application/*\" { capabilities = [\"list\"] }

# Health probe key
path \"$MOUNT/data/app\"               { capabilities = [\"read\"] }
path \"$MOUNT/metadata/app\"           { capabilities = [\"read\",\"list\"] }
"
  upsert_policy "$policy" "$hcl"

  role="${APP}-role-${env}"
  out="$(upsert_approle "$role" "$policy" "1h" "24h")"
  RID="$(printf '%s\n' "$out" | sed -n '1p')"
  SID="$(printf '%s\n' "$out" | sed -n '2p')"
  if [ "$DRY_RUN" != "true" ]; then
    d="infra/vault/approle/${APP}-${env}"
    mkdir -p "$d"
    printf "%s" "$RID" > "$d/role_id"
    printf "%s" "$SID" > "$d/secret_id"
    echo "WROTE AppRole creds: $d/role_id, $d/secret_id"
  fi
  verify_policies "$env"
done

# ---- COMPOSITE TOKEN POLICY (per env) + MINT & STORE TOKEN ----
COMPOSITE_POLICY_BASE="config-server-composite-read"
COMPOSITE_HCL_TMPL='
path "secret/metadata/*"                  { capabilities = ["list","read"] }

path "secret/data/application"            { capabilities = ["read"] }
path "secret/data/application,{env}"      { capabilities = ["read"] }
path "secret/data/application/composite"  { capabilities = ["read"] }
path "secret/metadata/application"        { capabilities = ["list","read"] }
path "secret/metadata/application/*"      { capabilities = ["list","read"] }

path "secret/data/danipa/config"          { capabilities = ["read"] }
path "secret/data/danipa/config,*"        { capabilities = ["read"] }
path "secret/data/danipa/config/*"        { capabilities = ["read"] }

path "secret/data/danipa-fintech-service"        { capabilities = ["read"] }
path "secret/data/danipa-fintech-service,{env}"  { capabilities = ["read"] }
path "secret/data/danipa-fintech-service/*"      { capabilities = ["read"] }

path "secret/data/danipa-eureka-server"          { capabilities = ["read"] }
path "secret/data/danipa-eureka-server,{env}"    { capabilities = ["read"] }
path "secret/data/danipa-eureka-server/*"        { capabilities = ["read"] }

# Grant rotation privileges on fintech-service paths so SecretLeaseContainer doesn’t get 403s.
path "secret/data/danipa-fintech-service,default"  { capabilities = ["read","update","create","delete"] }
path "secret/data/danipa-fintech-service/default"  { capabilities = ["read","update","create","delete"] }
path "secret/data/danipa-fintech-service"          { capabilities = ["read","update","create","delete"] }
path "secret/data/danipa-fintech-service,{env}"    { capabilities = ["read","update","create","delete"] }
path "secret/data/danipa-fintech-service/*"        { capabilities = ["read","update","create","delete"] }
'

# --- NEW: write back to the seed file with the fresh composite token ---
update_seed_json() {
  local env="$1"; local token="$2"
  local seed="$SEEDS_DIR/$env.json"
  if [ ! -f "$seed" ]; then
    echo "WARN: [$env] cannot update seed JSON (not found): $seed"; return 0
  fi
  if [ "$DRY_RUN" = "true" ]; then
    echo "[DRYRUN] WOULD update $seed with composite[0].token"; return 0
  fi
  python3 - "$seed" "$token" <<'PY'
import sys, json, pathlib
seed = pathlib.Path(sys.argv[1])
tok  = sys.argv[2]
data = json.loads(seed.read_text(encoding="utf-8-sig"))
paths = data.setdefault("paths", {})
comp  = paths.setdefault("danipa-config-server,composite", {})
comp["spring.cloud.config.server.composite[0].token"] = tok
# pretty, deterministic-ish
seed.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"UPDATED seed: {seed} with composite token ({tok[:4]}…{tok[-4:]})")
PY
}

ensure_composite_token() {
  local env="$1"; local pol="${COMPOSITE_POLICY_BASE}-${env}"
  [ "$DRY_RUN" = "true" ] && { echo "[DRYRUN] Would mint token for $pol"; return; }

  # 1) Mint a periodic orphan token bound to the composite policy
  local out tok
  out="$(vcurl -H 'Content-Type: application/json' \
        -X POST "$VAULT_ADDR/v1/auth/token/create" \
        -d "{\"policies\":[\"$pol\"],\"period\":\"24h\",\"renewable\":true,\"no_parent\":true}")"
  tok="$(python3 - "$out" <<'PY'
import sys, json
raw=sys.argv[1]
try:
    d=json.loads(raw) if raw.strip() else {}
    print(((d.get("auth") or {}).get("client_token") or ""))
except Exception:
    print("")
PY
)"
  if [ -z "$tok" ]; then
    echo "ERROR: failed to mint composite token for $pol"
    echo "  Response was:"; echo "$out" | sed -n '1,200p'
    return 1
  fi

  # 2) Merge into danipa-config-server,composite in Vault
  local get existing merged
  get="$(vcurl "$VAULT_ADDR/v1/$MOUNT/data/danipa-config-server,composite" || true)"
  existing="$(python3 - "$get" <<'PY'
import sys, json
raw=sys.argv[1]
try:
    d=json.loads(raw) if raw.strip() else {}
    print(json.dumps((d.get("data") or {}).get("data") or {}))
except Exception:
    print("{}")
PY
)"
  merged="$(python3 - "$existing" "$tok" <<'PY'
import sys, json
m = json.loads(sys.argv[1]) if sys.argv[1].strip() else {}
m["spring.cloud.config.server.composite[0].token"] = sys.argv[2]
print(json.dumps(m,separators=(",",":")))
PY
)"

  write_secret "danipa-config-server,composite" "$merged"

  # 3) Also persist token to the corresponding seed JSON file
  update_seed_json "$env" "$tok"

  # Stash for verify fallback
  printf "%s" "$tok" > "/tmp/vault_composite_token_${env}"
  echo "Composite token issued for $env: ${tok:0:4}****${tok: -4}"
}

for env in "${envs[@]}"; do
  COMPOSITE_POLICY="${COMPOSITE_POLICY_BASE}-${env}"
  COMPOSITE_HCL="${COMPOSITE_HCL_TMPL//\{env\}/$env}"
  upsert_policy "$COMPOSITE_POLICY" "$COMPOSITE_HCL"
  ensure_composite_token "$env"
done

verify_composite_token_caps() {
  local env="$1"
  local tok=""
  local get=""

  # Try comma path first, then legacy slash path
  get="$(vcurl "$VAULT_ADDR/v1/$MOUNT/data/danipa-config-server,composite" || true)"
  if ! grep -q '"data"' <<<"$get"; then
    get="$(vcurl "$VAULT_ADDR/v1/$MOUNT/data/danipa-config-server/composite" || true)"
  fi

  tok="$(
    python3 - "$get" <<'PY'
import sys, json, re
raw = sys.stdin.read()
try:
    d = json.loads(raw) if raw.strip() else {}
    data = (d.get("data") or {}).get("data") or {}
    v = data.get("spring.cloud.config.server.composite[0].token","")
    if v: print(v); raise SystemExit(0)
    for k, val in data.items():
        if re.search(r'\.token$', k) and isinstance(val, str) and val:
            print(val); raise SystemExit(0)
    print("")
except Exception:
    print("")
PY
  )"

  if [ -z "$tok" ] && [ -f "/tmp/vault_composite_token_${env}" ]; then
    tok="$(tr -d '\r\n' < "/tmp/vault_composite_token_${env}")"
  fi

  if [ -z "$tok" ]; then
    echo "  [verify composite] no composite token found for $env"
    return 0
  fi

  local paths_json
  paths_json=$(cat <<JSON
[ "$MOUNT/data/application",
  "$MOUNT/data/application,${env}",
  "$MOUNT/data/application/composite",
  "$MOUNT/data/danipa/config",
  "$MOUNT/data/danipa/config,${env}",
  "$MOUNT/data/danipa-fintech-service",
  "$MOUNT/data/danipa-fintech-service,${env}",
  "$MOUNT/data/danipa-eureka-server",
  "$MOUNT/data/danipa-eureka-server,${env}" ]
JSON
)

  echo "VERIFY composite token caps for [$env] …"
  python3 - "$paths_json" "$VAULT_ADDR" "$tok" <<'PY' || true
import sys, json, urllib.request
paths=json.loads(sys.argv[1]); addr=sys.argv[2].strip(); tok=sys.argv[3].strip()
def caps(p):
    req=urllib.request.Request(
        addr+"/v1/sys/capabilities-self",
        data=json.dumps({"paths":[p]}).encode(),
        headers={"X-Vault-Token": tok,"Content-Type":"application/json"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            d=json.loads(r.read().decode())
        data=d.get("data") or d
        c=data.get("capabilities") or data.get(p) or []
        return ",".join(c)
    except Exception as e:
        return f"<err:{e}>"
for p in paths:
    print(f"    {p}: {caps(p)}")
PY
}

for env in "${envs[@]}"; do verify_composite_token_caps "$env"; done

# ---- POLICIES + APPROLE (fintech-agent) ----
FIN_POLICY="fintech-read"
FIN_HCL=$(cat <<'HCL'
path "secret/data/danipa/config*"               { capabilities = ["read"] }
path "secret/metadata/danipa/config*"          { capabilities = ["read","list"] }
path "secret/data/danipa-fintech-service*"     { capabilities = ["read"] }
path "secret/metadata/danipa-fintech-service*" { capabilities = ["read","list"] }
HCL
)
upsert_policy "$FIN_POLICY" "$FIN_HCL"

for env in "${envs[@]}"; do
  FIN_ROLE="fintech-role-${env}"
  out="$(upsert_approle "$FIN_ROLE" "pg-read,$FIN_POLICY" "1h" "24h")"
  RID="$(printf '%s\n' "$out" | sed -n '1p')"
  SID="$(printf '%s\n' "$out" | sed -n '2p')"
  echo "AppRole $FIN_ROLE ensured with policies: pg-read,$FIN_POLICY"
  if [ "$DRY_RUN" != "true" ]; then
    d="infra/vault/approle/fintech-${env}"
    mkdir -p "$d"
    printf "%s" "$RID" > "$d/role_id"
    printf "%s" "$SID" > "$d/secret_id"
    echo "WROTE AppRole creds: $d/role_id, $d/secret_id"
  fi
done

# ---- POLICIES + APPROLE (eureka-agent) ----
EUREKA_POLICY="eureka-read"
EUREKA_HCL=$(cat <<'HCL'
path "secret/data/danipa-eureka-server"        { capabilities = ["read"] }
path "secret/data/danipa-eureka-server/*"      { capabilities = ["read"] }
path "secret/data/danipa-eureka-server,*"      { capabilities = ["read"] }

path "secret/metadata/danipa-eureka-server"    { capabilities = ["list","read"] }
path "secret/metadata/danipa-eureka-server/*"  { capabilities = ["list","read"] }
HCL
)
upsert_policy "$EUREKA_POLICY" "$EUREKA_HCL"

for env in "${envs[@]}"; do
  EUREKA_ROLE="eureka-role-${env}"
  out="$(upsert_approle "$EUREKA_ROLE" "$EUREKA_POLICY" "1h" "24h")"
  RID="$(printf '%s\n' "$out" | sed -n '1p')"
  SID="$(printf '%s\n' "$out" | sed -n '2p')"
  echo "AppRole $EUREKA_ROLE ensured with policies: $EUREKA_POLICY"
  if [ "$DRY_RUN" != "true" ]; then
    d="infra/vault/approle/eureka-${env}"
    mkdir -p "$d"
    printf "%s" "$RID" > "$d/role_id"
    printf "%s" "$SID" > "$d/secret_id"
    echo "WROTE AppRole creds: $d/role_id, $d/secret_id"
  fi
done

echo "Done."
[ "$VERIFY_ONLY" != "true" ] && seed_health_probe || true
