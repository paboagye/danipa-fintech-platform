#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo "🔄 Restarting DB stack..."
"${SCRIPT_DIR}/stop_db_stack.sh" || true
sleep 2
"${SCRIPT_DIR}/start_db_stack.sh"
echo "✅ Restart complete."
