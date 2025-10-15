#!/usr/bin/env bash
set -euo pipefail

# Usage (env or flags):
#   GIT_URI=https://github.com/OWNER/REPO.git GIT_TOKEN=ghp_xxx ./test-config-repo.sh
#   ./test-config-repo.sh --uri https://github.com/OWNER/REPO.git --pat ghp_xxx [--user x-access-token]
#
# Notes:
#  - We avoid putting the PAT in the URL. Instead we send Basic auth via header:
#      git -c http.extraHeader="Authorization: Basic <base64(user:pat)>"
#  - This prevents shell history / process list leaks and avoids URL parsing bugs.
#  - Requires: bash, curl, git, base64, sed

GIT_URI="${GIT_URI:-}"
GIT_USER="${GIT_USER:-x-access-token}"
GIT_TOKEN="${GIT_TOKEN:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uri)   GIT_URI="$2"; shift 2 ;;
    --user)  GIT_USER="$2"; shift 2 ;;
    --pat)   GIT_TOKEN="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -z "${GIT_URI}" || -z "${GIT_TOKEN}" ]]; then
  echo "ERROR: Provide --uri and --pat (or env GIT_URI and GIT_TOKEN)." >&2
  exit 2
fi

need() { command -v "$1" >/dev/null || { echo "ERROR: missing '$1'"; exit 2; }; }
need curl; need git; need base64; need sed

# Derive owner/repo from URI like https://github.com/owner/repo.git
if [[ "${GIT_URI}" =~ github\.com[:/]+([^/]+)/([^/.]+)(\.git)?$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
else
  echo "ERROR: GIT_URI does not look like a GitHub HTTPS URL: ${GIT_URI}" >&2
  exit 2
fi

mask_pat() {
  local p="$1" n=${#1}
  if (( n <= 6 )); then printf '%s' '***'; else printf '%s***%s' "${p:0:3}" "${p: -3}"; fi
}

BASIC_B64="$(printf '%s:%s' "$GIT_USER" "$GIT_TOKEN" | base64 -w 0 2>/dev/null || printf '%s' | base64)"
MASKED_PAT="$(mask_pat "$GIT_TOKEN")"

echo "== Inputs =="
echo "  URI       : ${GIT_URI}"
echo "  Username  : ${GIT_USER}"
echo "  PAT       : ${MASKED_PAT}"
echo "  Owner/Repo: ${OWNER}/${REPO}"
echo

api() {  # $1 = path under api.github.com, return HTTP code
  curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Basic ${BASIC_B64}" \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com$1"
}

echo "== Test 1: Token validity (/user) =="
CODE="$(api /user)"
echo "  HTTP ${CODE}"
if [[ "${CODE}" == "200" ]]; then
  echo "  ✅ Token looks valid."
else
  echo "  ❌ Token invalid or insufficient. Fix PAT first."
  exit 1
fi
echo

echo "== Test 2: Repo visibility via GitHub API =="
CODE="$(api "/repos/${OWNER}/${REPO}")"
echo "  HTTP ${CODE} for /repos/${OWNER}/${REPO}"
if [[ "${CODE}" == "200" ]]; then
  echo "  ✅ Token can see the repo (API)."
else
  echo "  ❌ Token cannot see the repo via API. Check repo access or SSO org authorization."
  exit 1
fi
echo

echo "== Test 3: Git over HTTPS (git ls-remote with Basic auth header) =="
set +e
# IMPORTANT: do NOT embed PAT in the URL; use Authorization header instead.
git -c http.extraHeader="Authorization: Basic ${BASIC_B64}" \
    -c credential.helper= \
    ls-remote --heads --quiet "https://github.com/${OWNER}/${REPO}.git" >/dev/null 2>git_test.err
STATUS=$?
set -e

if [[ $STATUS -eq 0 ]]; then
  echo "  ✅ Git fetch OK (credentials accepted by Git over HTTPS)."
else
  echo "  ❌ git ls-remote failed (status ${STATUS})."
  if grep -qiE 'not authorized|authentication|401|403' git_test.err; then
    echo "     Looks like auth was rejected. Common causes:"
    echo "      - PAT missing 'repo' scope"
    echo "      - Token not SSO-authorized for the org"
    echo "      - Org policy blocking classic PAT (try a fine-grained PAT with Contents:Read)"
  elif grep -qi 'URL rejected: Port number' git_test.err; then
    echo "     Your previous failure matched a malformed URL. Ensure you do NOT use:"
    echo "       https://x-access-token:PAT/github.com/owner/repo.git  (WRONG)"
    echo "     and DO NOT embed the PAT at all. This script uses the proper header auth."
  fi
  echo "     --- raw error ---"
  sed -e 's/'"${GIT_TOKEN}"'/***REDACTED***/g' git_test.err
  rm -f git_test.err
  exit 1
fi
rm -f git_test.err
echo
echo "All tests passed. Your PAT can reach ${OWNER}/${REPO} via Git over HTTPS."
