#!/usr/bin/env bash
# config-server-logscan.sh
# Summarize Spring Config Server logs for quick troubleshooting.
# - Reads either a log file (-f) OR a Docker container's logs (-c).
# - Detects exceptions, common failure hints (e.g., JGit auth), and startup success.
# - Exits 0 on "looks healthy", 1 if suspicious (errors/exceptions/no-startup).

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  config-server-logscan.sh -f /path/to/app.log                    # from file
  config-server-logscan.sh -c danipa-config-server [-n 5000]      # from docker logs
Options:
  -f  Log file path to read.
  -c  Docker container name to read with `docker logs`.
  -n  Tail N lines (default: 10000).
Notes:
  • Verdict is based on presence of errors/exceptions and startup success markers.
  • Returns non-zero if problems are detected.
USAGE
}

LOGSRC=""
TAILN=10000
while getopts ":f:c:n:h" opt; do
  case "$opt" in
    f) LOGSRC="file:$OPTARG" ;;
    c) LOGSRC="docker:$OPTARG" ;;
    n) TAILN="$OPTARG" ;;
    h|*) usage; exit 0 ;;
  esac
done

[ -z "$LOGSRC" ] && { usage; exit 2; }

# ---- Fetch logs into a temp file ----
TMP="$(mktemp)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

if [[ "$LOGSRC" == file:* ]]; then
  LOGFILE="${LOGSRC#file:}"
  [ -f "$LOGFILE" ] || { echo "ERROR: file not found: $LOGFILE" >&2; exit 2; }
  tail -n "$TAILN" "$LOGFILE" >"$TMP"
else
  CNAME="${LOGSRC#docker:}"
  docker logs --tail "$TAILN" "$CNAME" >"$TMP" 2>&1 || true
fi

# ---- Helpers ----
grep_json_escape() { sed 's/"/\"/g' | sed 's/\\/\\\\/g'; }

# ---- Collect indicators ----
START_MARK="$(grep -E 'Started .* in [0-9.]+ seconds' "$TMP" | tail -1 || true)"
START_APP="$(grep -E 'Started (ConfigServerApplication|.*Application)\b' "$TMP" | tail -1 || true)"
TOMCAT_OK="$(grep -E 'Tomcat started on port|Netty started on port|Started Jetty' "$TMP" | tail -1 || true)"
LISTEN_OK="$(grep -E 'Started .* in|Tomcat started|Netty started|Jetty started' "$TMP" | tail -1 || true)"

# Vault & profile hints
VAULT_AUTH="$(grep -E 'Starting with Vault auth =|spring\.cloud\.vault' "$TMP" | tail -1 || true)"
VAULT_MISS="$(grep -E 'Vault location \[[^]]+\] not resolvable' "$TMP" | sort -u || true)"
PROFILE_LINE="$(grep -E 'The following [0-9]+ profile.*active' "$TMP" | tail -1 || true)"

# Git / JGit symptoms
JGitAuth="$(grep -E 'org\.eclipse\.jgit.*not authorized|https://.*: not authorized' "$TMP" | sort -u || true)"
JGitErrors="$(grep -E 'MultipleJGitEnvironmentRepository|JGitEnvironmentRepository|CloneCommand' "$TMP" | tail -1 || true)"

# Exception & ERROR tallies
# Grab stacktrace starters and typical markers
EX_LINES="$(grep -nE '(^|\s)(ERROR|FATAL)\b|Exception:|Caused by:|Stacktrace|Traceback|not authorized' "$TMP" || true)"

# Group “exception type / error message” heuristically
mapfile -t TOP_ERRS < <(
  echo "$EX_LINES" |
  sed -E 's/^[^:]*://; s/\x1B\[[0-9;]*[mK]//g' |
  awk '
    /Caused by:/ { sub(/^.*Caused by:[[:space:]]*/,""); print; next }
    /Exception/ { print }
    /( ERROR | FATAL )/ { print }
  ' |
  sed -E 's/\s+at\s+.*//; s/\s*\[[^]]+\]\s*//; s/\s{2,}/ /g' |
  awk 'NF>0' |
  sort | uniq -c | sort -nr | head -10
)

ERR_COUNT_TOTAL="$(echo "$EX_LINES" | awk 'NF>0' | wc -l | tr -d ' ')"

# ---- Simple heuristics for verdict ----
startup_ok=false
if [[ -n "$START_MARK" || -n "$TOMCAT_OK" || -n "$LISTEN_OK" ]]; then
  startup_ok=true
fi

suspicious=false
if (( ERR_COUNT_TOTAL > 0 )); then suspicious=true; fi
# Treat JGit "not authorized" as suspicious even if app continued
if [[ -n "$JGitAuth" ]]; then suspicious=true; fi
# Treat repeated Vault misses as suspicious
if [[ -n "$VAULT_MISS" ]]; then suspicious=true; fi

# If we saw an explicit "Started ... in X seconds" and no errors => healthy
if $startup_ok && (( ERR_COUNT_TOTAL == 0 )) && [[ -z "$JGitAuth" && -z "$VAULT_MISS" ]]; then
  suspicious=false
fi

# ---- Report ----
echo "============ Config Server Log Report ============"
echo "Source         : ${LOGSRC/file:/file: } (last ${TAILN} lines)"
echo "Profile        : ${PROFILE_LINE:-<none found>}"
echo "Vault auth     : ${VAULT_AUTH:-<not seen>}"
echo "Startup mark   : ${START_MARK:-<not seen>}"
echo "Runtime listen : ${TOMCAT_OK:-${LISTEN_OK:-<not seen>}}"
echo

if [[ -n "$JGitAuth" || -n "$JGitErrors" ]]; then
  echo "---- Git/JGit indicators ----"
  [[ -n "$JGitErrors" ]] && echo "$JGitErrors"
  [[ -n "$JGitAuth"  ]] && echo "$JGitAuth"
  echo
fi

if [[ -n "$VAULT_MISS" ]]; then
  echo "---- Vault lookups not resolvable (unique) ----"
  echo "$VAULT_MISS"
  echo
fi

echo "---- Exceptions / Errors (top 10 condensed) ----"
printf "%s\n" "${TOP_ERRS[@]:-<none found>}"
echo
echo "Totals: errors+exceptions lines = ${ERR_COUNT_TOTAL}"

echo
if $suspicious; then
  echo "VERDICT: ⚠️  Issues detected."
  $startup_ok && echo "         (App shows a startup signal but has error symptoms.)"
  [[ -n "$JGitAuth" ]] && echo "         JGit auth failed — check SPRING_CLOUD_CONFIG_SERVER_GIT_* in Vault/env."
  [[ -n "$VAULT_MISS" ]] && echo "         Some Vault paths not found — verify KV seeds & policy access."
  exit 1
else
  echo "VERDICT: ✅ Looks healthy."
  exit 0
fi
