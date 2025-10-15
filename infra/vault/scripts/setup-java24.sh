#!/usr/bin/env bash
# setup-java24.sh — install Temurin Java 24 via SDKMAN on WSL/Ubuntu
set -e -o pipefail

# --- Prereqs (Ubuntu/WSL) ---
if ! command -v curl >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y curl zip unzip ca-certificates
fi

# --- Install SDKMAN! if missing ---
if [ ! -s "$HOME/.sdkman/bin/sdkman-init.sh" ]; then
  echo "[*] Installing SDKMAN!"
  curl -s https://get.sdkman.io | bash
fi

# --- Initialize SDKMAN! (temporarily disable nounset) ---
# Save current nounset state, then disable
if ( set -o | grep -q 'nounset.*on' ); then _RESTORE_NOUNSET=1; set +u; else _RESTORE_NOUNSET=0; fi
# shellcheck source=/dev/null
source "$HOME/.sdkman/bin/sdkman-init.sh"
# Re-enable nounset if it was previously on
if [ "${_RESTORE_NOUNSET}" = "1" ]; then set -u; fi

# --- Install Java 24 (Temurin) & set default ---
# Turn off nounset for sdk subcommands too (SDKMAN uses dynamic vars/functions)
if ( set -o | grep -q 'nounset.*on' ); then _RESTORE_NOUNSET=1; set +u; else _RESTORE_NOUNSET=0; fi

# If a 24-tem is not installed, install it
if ! sdk list java | grep -E 'installed' | grep -qE '\b24\..*tem\b'; then
  echo "[*] Installing Temurin Java 24 via SDKMAN"
  yes | sdk install java 24-tem
fi

echo "[*] Setting Java 24 as default"
sdk default java 24-tem

# Re-enable nounset if it was previously on
if [ "${_RESTORE_NOUNSET}" = "1" ]; then set -u; fi

# --- Persist JAVA_HOME and PATH using SDKMAN 'current' symlink ---
BASHRC="$HOME/.bashrc"
LINE1='export JAVA_HOME="$SDKMAN_CANDIDATES_DIR/java/current"'
LINE2='export PATH="$JAVA_HOME/bin:$PATH"'

grep -qxF "$LINE1" "$BASHRC" || echo "$LINE1" >> "$BASHRC"
grep -qxF "$LINE2" "$BASHRC" || echo "$LINE2" >> "$BASHRC"

# --- Export for current shell too ---
# Safely (no nounset issues) compute JAVA_HOME via SDKMAN
if ( set -o | grep -q 'nounset.*on' ); then _RESTORE_NOUNSET=1; set +u; else _RESTORE_NOUNSET=0; fi
export JAVA_HOME="${SDKMAN_CANDIDATES_DIR}/java/current"
export PATH="$JAVA_HOME/bin:$PATH"
if [ "${_RESTORE_NOUNSET}" = "1" ]; then set -u; fi

# --- Verify ---
echo
echo "[*] Verification:"
java --version
echo "JAVA_HOME=$JAVA_HOME"
echo
echo "[✓] Done. New shells will have JAVA_HOME via ~/.bashrc"
