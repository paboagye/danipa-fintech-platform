#!/bin/sh
# init-unseal.sh — init or unseal Vault using /keys/vault-keys.json (no jq)
set -eu

VAULT_ADDR="http://vault:8200"
OUTFILE="/keys/vault-keys.json"
UNSEAL_ONLY="false"
CLI_KEY=""

# --- args ---
while [ $# -gt 0 ]; do
  case "$1" in
    --vault-addr) VAULT_ADDR="$2"; shift 2;;
    --outfile)    OUTFILE="$2"; shift 2;;
    --unseal-only) UNSEAL_ONLY="true"; shift 1;;
    --key)        CLI_KEY="$2"; shift 2;;
    -h|--help)
      echo "usage: $0 [--vault-addr URL] [--outfile PATH] [--unseal-only] [--key BASE64]"; exit 0;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done

# tiny helpers
http() { # method path [json]
  m="$1"; p="$2"; b="${3:-}"
  url="${VAULT_ADDR%/}/${p#'/'}"
  if [ -n "$b" ]; then
    curl -sS -H "Content-Type: application/json" -X "$m" --data "$b" "$url"
  else
    curl -sS -X "$m" "$url"
  fi
}

json_get() {  # json key → prints value or empty
  python3 - "$1" "$2" <<'PY'
import sys,json
raw=sys.argv[1]; key=sys.argv[2]
try: d=json.loads(raw)
except Exception: d={}
cur=d
for part in key.split('.'):
  if isinstance(cur,dict) and part in cur: cur=cur[part]
  else: cur=None; break
if isinstance(cur,(dict,list)):
  import json as j; print(j.dumps(cur)); sys.exit(0)
print("" if cur is None else cur)
PY
}

read_file_json() { # file → raw (BOM tolerant) or empty
  [ -f "$1" ] || { echo ""; return; }
  python3 - "$1" <<'PY'
import sys,pathlib
p=pathlib.Path(sys.argv[1])
try: print(p.read_text(encoding="utf-8-sig"))
except Exception: print("")
PY
}

write_keys_payload() { # addr root_token keys_json outfile
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys,json,datetime
addr,token,keys_json,out=sys.argv[1:5]
try: keys=json.loads(keys_json)
except Exception: keys=[]
doc={"vault_addr":addr,"root_token":token,"unseal_keys_b64":keys,
     "created_utc":datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")}
open(out,"w",encoding="utf-8").write(json.dumps(doc,indent=2))
print(out)
PY
}

# --- check status ---
SEAL_STATUS="$(http GET v1/sys/seal-status || echo '{}')"
INIT="$(json_get "$SEAL_STATUS" initialized)"; [ -z "$INIT" ] && INIT="false"
SEALED="$(json_get "$SEAL_STATUS" sealed)";      [ -z "$SEALED" ] && SEALED="true"

if [ "$UNSEAL_ONLY" = "true" ]; then
  KEY="$CLI_KEY"
  if [ -z "$KEY" ]; then
    RAW="$(read_file_json "$OUTFILE")"
    [ -z "$RAW" ] && { echo "ERROR: keys file not found: $OUTFILE" >&2; exit 10; }
    KEYS_JSON="$(json_get "$RAW" unseal_keys_b64)"
    [ -z "$KEYS_JSON" ] && KEYS_JSON="$(json_get "$RAW" UnsealKeys)"
    [ -z "$KEYS_JSON" ] && { echo "ERROR: keys file lacks unseal keys." >&2; exit 11; }
    KEY="$(python3 - "$KEYS_JSON" <<'PY'
import sys,json; arr=json.loads(sys.argv[1]); print(arr[0] if arr else "", end="")
PY
)"
  fi
  [ -z "$KEY" ] && { echo "ERROR: no unseal key available." >&2; exit 12; }
  RESP="$(http PUT v1/sys/unseal "{\"key\":\"$KEY\"}")"
  [ "$(json_get "$RESP" sealed)" = "false" ] && { echo "==> Unsealed (or already)."; exit 0; }
  echo "ERROR: Unseal attempt failed:"; echo "$RESP"; exit 13
fi

if [ "$INIT" = "false" ]; then
  echo "==> Initializing Vault (1/1) ..."
  INIT_JSON="$(http POST v1/sys/init '{"secret_shares":1,"secret_threshold":1}')"
  ROOT_TOKEN="$(json_get "$INIT_JSON" root_token)"
  KEYS_JSON="$(json_get "$INIT_JSON" keys_base64)"
  [ -z "$ROOT_TOKEN" ] || [ -z "$KEYS_JSON" ] && { echo "ERROR: init missing fields"; echo "$INIT_JSON"; exit 4; }
  WRITTEN="$(write_keys_payload "$VAULT_ADDR" "$ROOT_TOKEN" "$KEYS_JSON" "$OUTFILE")"
  echo "==> Wrote $WRITTEN"
  # unseal with first key
  FIRST_KEY="$(python3 - "$KEYS_JSON" <<'PY'
import sys,json; arr=json.loads(sys.argv[1]); print(arr[0] if arr else "", end="")
PY
)"
  RESP="$(http PUT v1/sys/unseal "{\"key\":\"$FIRST_KEY\"}")"
  [ "$(json_get "$RESP" sealed)" = "false" ] || { echo "ERROR: unseal failed"; echo "$RESP"; exit 6; }
  echo "==> Unsealed."
  echo "DONE."
  exit 0
fi

echo "==> Vault already initialized."
if [ "$SEALED" = "true" ]; then
  RAW="$(read_file_json "$OUTFILE")"
  [ -z "$RAW" ] && { echo "ERROR: $OUTFILE not found; cannot unseal." >&2; exit 7; }
  KEYS_JSON="$(json_get "$RAW" unseal_keys_b64)"
  [ -z "$KEYS_JSON" ] && KEYS_JSON="$(json_get "$RAW" UnsealKeys)"
  [ -z "$KEYS_JSON" ] && { echo "ERROR: $OUTFILE lacks unseal keys." >&2; exit 8; }
  # try keys in order (even though threshold=1)
  COUNT="$(python3 - "$KEYS_JSON" <<'PY'
import sys,json; print(len(json.loads(sys.argv[1])))
PY
)"
  i=0
  while [ "$i" -lt "$COUNT" ]; do
    KEY="$(python3 - "$KEYS_JSON" "$i" <<'PY'
import sys,json; arr=json.loads(sys.argv[1]); print(arr[int(sys.argv[2])], end="")
PY
)"
    RESP="$(http PUT v1/sys/unseal "{\"key\":\"$KEY\"}")"
    [ "$(json_get "$RESP" sealed)" = "false" ] && break
    i=$((i+1))
  done
  FINAL="$(http GET v1/sys/seal-status || echo '{}')"
  [ "$(json_get "$FINAL" sealed)" = "false" ] && { echo "==> Unsealed."; exit 0; }
  echo "ERROR: Unseal failed — still sealed."; exit 9
else
  echo "==> Vault already unsealed."
fi
