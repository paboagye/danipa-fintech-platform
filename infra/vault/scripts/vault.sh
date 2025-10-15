#!/usr/bin/env bash
set -euo pipefail
REPO="/mnt/c/dev/repositories/danipa-fintech-platform"
make -C "$REPO" -f infra/vault/scripts/Makefile "$@"
