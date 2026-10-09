# shellcheck shell=bash
#
# ## coder_api.sh — reach this stack's own control plane (sourced; never executed)
#
# Three scripts (coder-agents.sh, push-template.sh, new-workspace.sh) need the
# same reach into the compose stack: psql one-offs against Coder's database
# container and coder-CLI runs inside the coder service, both with the session
# token kept OFF the argv that `ps` shows. The knobs below default to the real
# stack and can be overridden per test or per checkout.
#
# Usage (from an entry script, after `set -euo pipefail` and the repo-root `cd`):
#   # shellcheck source=lib/coder_api.sh disable=SC1091
#   source "scripts/lib/coder_api.sh"

# ── Knobs ────────────────────────────────────────────────────────────────────

# DOCKER_BIN may hold more than one word ("sudo docker"); it is intentionally
# left unquoted at the call sites below, which is what lets that override work.
# timeout(1) is an external binary and can exec an EXECUTABLE FILE only, never a
# shell function, so every wrapper here keeps the command after the timeout cap
# starting at DOCKER_BIN itself.
DOCKER_BIN="${DOCKER_BIN:-docker}"
DB_SERVICE="${DB_SERVICE:-db}"
DB_USER="${DB_USER:-coder}"
DB_NAME="${DB_NAME:-coder}"
CODER_SERVICE="${CODER_SERVICE:-coder}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-20}"

# ── Wrappers ─────────────────────────────────────────────────────────────────

# psql_sql <sql> — run one statement against Coder's database inside the db
# service, capped, printing stdout AND stderr. ON_ERROR_STOP makes a failed
# statement a non-zero exit instead of a quiet warning, which would otherwise
# surface later as an unexplained auth failure.
# @function psql_sql
# Run one SQL statement inside the db service. Stdout and stderr are both printed.
# Globals:
#   DOCKER_BIN, PROBE_TIMEOUT, DB_SERVICE, DB_USER, DB_NAME
# Arguments:
#   $1 - SQL
# Outputs:
#   psql's combined output
# Returns:
#   0 on success; the command's status otherwise
psql_sql() {
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  timeout "${PROBE_TIMEOUT}" ${DOCKER_BIN} compose exec -T "${DB_SERVICE}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q -c "$1" </dev/null 2>&1
}

# psql_query <sql> — run one single-column query and print ONLY its value,
# whitespace-trimmed. -q -tA suppress the command status and headers that a
# plain -t still prints.
# @function psql_query
# Run one single-column query and print only the trimmed value.
# Globals:
#   DOCKER_BIN, PROBE_TIMEOUT, DB_SERVICE, DB_USER, DB_NAME
# Arguments:
#   $1 - SQL
# Outputs:
#   The value with whitespace removed
# Returns:
#   0 on success; the command's status otherwise
psql_query() {
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  timeout "${PROBE_TIMEOUT}" ${DOCKER_BIN} compose exec -T "${DB_SERVICE}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q -tAc "$1" </dev/null 2>&1 |
    tr -d '[:space:]'
}

# coder_exec <coder-args...> — run the coder CLI inside the coder service with
# CODER_URL and CODER_SESSION_TOKEN passed through the environment (never via
# argv, where `ps` would show them) and stdin closed, so -T stays parseable and
# this is safe inside a pipe. The caller must have set CONTAINER_API_URL and
# session_token first (empty values stay empty rather than tripping `set -u`).
# @function coder_exec
# Run the coder CLI inside the coder service. The token is an env var, not argv.
# Globals:
#   DOCKER_BIN, CODER_SERVICE, CONTAINER_API_URL, session_token, VERIFY_TIMEOUT, PROBE_TIMEOUT
# Arguments:
#   $@ - coder arguments
# Outputs:
#   The CLI's own output
# Returns:
#   The CLI's status
coder_exec() {
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  CODER_URL="${CONTAINER_API_URL:-}" CODER_SESSION_TOKEN="${session_token:-}" \
    timeout "${VERIFY_TIMEOUT:-${PROBE_TIMEOUT}}" ${DOCKER_BIN} compose exec -T \
    -e CODER_URL -e CODER_SESSION_TOKEN "${CODER_SERVICE}" \
    coder "$@" </dev/null
}
