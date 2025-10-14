#!/usr/bin/env bash
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-$(command -v docker)}"
EXEC() { "$DOCKER_BIN" exec -it "$@"; }

ACTION="${1:-}"
CN="${2:-}"

if [[ -z "${ACTION}" || -z "${CN}" ]]; then
  echo "Usage: $(basename "$0") issue <common-name>   # e.g. config-server" >&2
  exit 2
fi

TLS_DIR="${TLS_DIR:-$(pwd)/infra/config-server/tls}"
CA_CONT="${CA_CONT:-step-ca}"

DEFAULT_SANS=( "$CN" "config-server" "localhost" "127.0.0.1" )
EXTRA_SANS=( ${SANS:-} )
ALL_SANS=( "${DEFAULT_SANS[@]}" "${EXTRA_SANS[@]}" )
SAN_FLAGS=()
for s in "${ALL_SANS[@]}"; do SAN_FLAGS+=( "--san=$s" ); done

case "$ACTION" in
  issue)
    EXEC "$CA_CONT" sh -lc "
      set -euo pipefail
      umask 077
      OUT=/tmp/config-server
      mkdir -p \"\$OUT\"

      CA_CRT=/home/step/certs/intermediate_ca.crt
      CA_KEY=/home/step/secrets/intermediate_ca_key

      PW_FILE=''
      for f in /home/step/secrets/password /home/step/secrets/ca-password /home/step/secrets/passwd; do
        [ -s \"\$f\" ] && PW_FILE=\"\$f\" && break
      done
      PW_FLAG=''
      [ -n \"\$PW_FILE\" ] && PW_FLAG=\"--password-file=\$PW_FILE\"

      step certificate create \"$CN\" \
        \"\$OUT/server-fullchain.crt\" \"\$OUT/server.key\" \
        ${SAN_FLAGS[*]} \
        --not-after=\"${NOT_AFTER:-9528h}\" \
        --bundle \
        --ca=\"\$CA_CRT\" --ca-key=\"\$CA_KEY\" \$PW_FLAG \
        --no-password --insecure \
        --force
      ls -l \"\$OUT\"
    "

    mkdir -p "$TLS_DIR"
    "$DOCKER_BIN" cp "$CA_CONT:/tmp/config-server/server-fullchain.crt" "$TLS_DIR/server-fullchain.crt"
    "$DOCKER_BIN" cp "$CA_CONT:/tmp/config-server/server.key"          "$TLS_DIR/server.key"
    cp -f infra/step/root_ca.crt "$TLS_DIR/root_ca.crt"
    chmod 0644 "$TLS_DIR/server-fullchain.crt"
    chmod 0600 "$TLS_DIR/server.key"

    openssl x509 -in "$TLS_DIR/server-fullchain.crt" -noout -subject -issuer -dates -ext subjectAltName || true
    echo "Wrote: $TLS_DIR/server-fullchain.crt and $TLS_DIR/server.key"
    ;;
  *)
    echo "Unknown action: $ACTION" >&2; exit 1 ;;
esac
