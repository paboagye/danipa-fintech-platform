# infra/vault/scripts/cert/vault_cert.sh
#!/usr/bin/env bash
set -euo pipefail

# Always call the real docker binary (avoid aliases that add -it)
DOCKER_BIN="${DOCKER_BIN:-$(command -v docker)}"
EXEC() { "$DOCKER_BIN" exec -it "$@"; }   # no TTY

ACTION="${1:-}"
CN="${2:-}"

if [[ -z "${ACTION}" || -z "${CN}" ]]; then
  echo "Usage: $(basename "$0") issue <common-name>   # e.g. vault.local.danipa.com" >&2
  exit 2
fi
if [[ "${CN}" == "issue" ]]; then
  echo "ERROR: You passed only one argument. Use: $(basename "$0") issue <CN>" >&2
  exit 2
fi

TLS_DIR="${TLS_DIR:-$(pwd)/infra/vault/tls}"
CA_CONT="${CA_CONT:-step-ca}"
ROOT_INSIDE="/tmp/root_ca.crt"

# Default SANs; can add more via env:  SANS="api.vault.local 10.0.0.10"
DEFAULT_SANS=( "$CN" "vault" "localhost" "127.0.0.1" )
EXTRA_SANS=( ${SANS:-} )
ALL_SANS=( "${DEFAULT_SANS[@]}" "${EXTRA_SANS[@]}" )
SAN_FLAGS=()
for s in "${ALL_SANS[@]}"; do SAN_FLAGS+=( "--san=$s" ); done
SAN_JOINED="${SAN_FLAGS[*]}"

echo ">> ACTION=${ACTION}  CN=${CN}"
echo ">> SANs: ${ALL_SANS[*]}"

case "${ACTION}" in
  issue)
    # Ensure CA root exists inside the CA container (copy once if missing)
    if ! EXEC "${CA_CONT}" test -s "${ROOT_INSIDE}" 2>/dev/null; then
      "$DOCKER_BIN" cp "${TLS_DIR}/root_ca.crt" "${CA_CONT}:${ROOT_INSIDE}"
    fi

    # Sign & bundle inside step-ca; unencrypted key; no prompts; overwrite any old files
    EXEC "${CA_CONT}" sh -lc "
      set -euo pipefail
      umask 077

      CA_CRT=/home/step/certs/intermediate_ca.crt
      CA_KEY=/home/step/secrets/intermediate_ca_key

      PW_FILE=''
      for f in /home/step/secrets/password /home/step/secrets/ca-password /home/step/secrets/passwd; do
        [ -s \"\$f\" ] && { PW_FILE=\"\$f\"; break; }
      done
      PW_FLAG=''
      [ -n \"\$PW_FILE\" ] && PW_FLAG=\"--ca-password-file=\$PW_FILE\"

      # remove any stale files to avoid overwrite prompts
      rm -f /tmp/server.crt /tmp/server.key

      DUR="${NOT_AFTER:-9528h}"
      step certificate create \"${CN}\" /tmp/server.crt /tmp/server.key \
        ${SAN_JOINED} \
        --not-after=\"\${DUR}\" \
        --bundle \
        --ca=\"\$CA_CRT\" \
        --ca-key=\"\$CA_KEY\" \
        \$PW_FLAG \
        --no-password --insecure \
        --force
    "

    # Copy artifacts back to host
    mkdir -p "${TLS_DIR}"
    "$DOCKER_BIN" cp "${CA_CONT}:/tmp/server.crt" "${TLS_DIR}/server.crt"
    "$DOCKER_BIN" cp "${CA_CONT}:/tmp/server.key" "${TLS_DIR}/server.key"
    chmod 0644 "${TLS_DIR}/server.crt"
    chmod 0600 "${TLS_DIR}/server.key"

    # Sanity
    awk 'BEGIN{c=0}/^-----BEGIN CERTIFICATE-----/{c++}END{print "certs_in_file=" c}' "${TLS_DIR}/server.crt"
    openssl x509 -in "${TLS_DIR}/server.crt" -noout -subject -issuer -dates || true
    echo "Wrote: ${TLS_DIR}/server.crt and ${TLS_DIR}/server.key"
    ;;

  token)
    echo "token action not wired yet; use 'issue' for local TLS issuance." >&2
    exit 2
    ;;

  *)
    echo "Unknown action: ${ACTION} (use 'issue' or 'token')" >&2
    exit 1
    ;;
esac
