#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## pg-apply-password.sh — re-apply POSTGRES_PASSWORD on every db start
# (container entrypoint; also sourced by the stack runners).
#
# The official postgres image only honours POSTGRES_PASSWORD on first volume
# init. A later rotation of CODER_PG_PASSWORD in .env (bootstrap replacing a
# change-me placeholder, a copied .env, a hand edit) recreates the db
# container with the new env but leaves the role inside coder-db on the old
# password. Coder then crash-loops with:
#   pq: password authentication failed for user "coder"
# while `pg_isready` still reports the db healthy.
#
# This script is the db service entrypoint. It starts the image's own
# docker-entrypoint.sh, waits until the server accepts local connections
# (trust on the unix socket), ALTER USER ... PASSWORD from the current
# POSTGRES_PASSWORD, and then waits on postgres so signals keep working.
# Compose bind-mounts this file read-only; the healthcheck authenticates over
# TCP with PGPASSWORD so Coder is not started until the role matches .env.
#
# The stack runners also source this file for restart_coder_if_pg_auth_failed
# (bounce coder after a password rotation) and start_coder_agents_wait (the
# Coder Agents seeder after compose up, so the first registered owner still
# gets providers without an Admin UI pass).
#
# Usage (compose, as the db entrypoint; command: ["postgres"] is required
# because a compose entrypoint override clears the image CMD):
#   /usr/local/bin/pg-apply-password.sh postgres
#
# Usage (from a stack runner, after common.sh):
#   # shellcheck source=lib/pg-apply-password.sh disable=SC1091
#   source "${SELF_DIR}/lib/pg-apply-password.sh"

# @function pg_password_dollar_tag
# Print a dollar-quote delimiter that does not appear in the password.
# Globals:
#   None
# Arguments:
#   $1 - the password
# Outputs:
#   A tag safe to wrap the password in $tag$password$tag$
# Returns:
#   0
pg_password_dollar_tag() {
  local password="${1:-}" tag="evoT1pw" n=0
  while [[ ${password} == *"${tag}"* ]]; do
    n=$((n + 1))
    tag="evoT1pw${n}"
  done
  printf '%s' "${tag}"
}

# @function pg_password_alter_sql
# Print an ALTER USER statement that sets one role's password via dollar quoting.
# Globals:
#   None
# Arguments:
#   $1 - role name
#   $2 - password
# Outputs:
#   One SQL statement ending in a newline
# Returns:
#   0
pg_password_alter_sql() {
  local role="${1:-}" password="${2:-}" tag ident
  tag="$(pg_password_dollar_tag "${password}")"
  ident="${role//\"/\"\"}"
  printf 'ALTER USER "%s" WITH PASSWORD $%s$%s$%s$;\n' \
    "${ident}" "${tag}" "${password}" "${tag}"
}

# @function pg_apply_role_password
# ALTER USER via the local socket (trust). Empty role or password is a no-op.
# Globals:
#   None
# Arguments:
#   $1 - role name
#   $2 - password
#   $3 - database name (default: the role)
# Outputs:
#   psql's own output
# Returns:
#   0 when skipped or applied; psql's status otherwise
pg_apply_role_password() {
  local role="${1:-}" password="${2:-}" db="${3:-}"
  if [[ -z ${role} || -z ${password} ]]; then
    return 0
  fi
  # SQL on stdin, not -c: a dollar-quote tag looks like a shell parameter
  # (`$evoT1pw$...`) and must not land in psql's argv either.
  pg_password_alter_sql "${role}" "${password}" |
    psql -U "${role}" -d "${db:-${role}}" -v ON_ERROR_STOP=1 -q
}

# @function pg_wait_ready
# Block until pg_isready succeeds, or until the postgres pid has exited.
# Globals:
#   None
# Arguments:
#   $1 - role name passed to pg_isready
#   $2 - pid of docker-entrypoint.sh / postgres (empty: wait forever)
# Outputs:
#   Nothing
# Returns:
#   0 when ready; 1 when the pid exited first
pg_wait_ready() {
  local role="${1:-postgres}" pid="${2:-}"
  until pg_isready -U "${role}" >/dev/null 2>&1; do
    if [[ -n ${pid} ]] && ! kill -0 "${pid}" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 0
}

# @function compose_up_or_diagnose_db
# Run compose up -d; on failure print recent db logs so the operator sees why.
# Globals:
#   None (calls run_compose when that function exists)
# Arguments:
#   None
# Outputs:
#   compose's own output; on failure, a note and the last db logs
# Returns:
#   0 when up succeeds; 1 when run_compose is missing; otherwise compose's status
compose_up_or_diagnose_db() {
  if ! declare -f run_compose >/dev/null 2>&1; then
    return 1
  fi
  if run_compose up -d; then
    return 0
  fi
  printf 'error: compose up failed; last db logs follow\n' >&2
  run_compose logs --tail 80 db || true
  return 1
}

# @function restart_coder_if_pg_auth_failed
# Bounce coder when recent compose logs show postgres password auth failure.
# Globals:
#   None (calls run_compose and log when those functions exist)
# Arguments:
#   None
# Outputs:
#   One line when coder is restarted; nothing when logs are clean or compose
#   is unavailable
# Returns:
#   0, or run_compose's status on restart
restart_coder_if_pg_auth_failed() {
  local logs=""
  if ! declare -f run_compose >/dev/null 2>&1; then
    return 0
  fi
  logs="$(run_compose logs --tail 30 coder 2>/dev/null || true)"
  if [[ ${logs} != *"password authentication failed"* ]]; then
    return 0
  fi
  if declare -f log >/dev/null 2>&1; then
    log "coder: postgres role password now matches .env; restarting coder so it reconnects"
  fi
  run_compose restart coder
}

# @function start_coder_agents_wait
# Background scripts/coder-agents.sh --apply --wait so first-user-later still
# gets the LiteLLM provider and model configs. Missing seeder (scratch tests
# that copy only docker-compose.yml) is a no-op. SKIP_CODER_AGENTS skips it.
# Globals:
#   SKIP_CODER_AGENTS, CODER_AGENTS_WAIT_SECS
# Arguments:
#   $1 - repo root that holds scripts/coder-agents.sh
# Outputs:
#   One note line when the seeder starts or is skipped by SKIP_CODER_AGENTS
# Returns:
#   0
start_coder_agents_wait() {
  local seeder="$1/scripts/coder-agents.sh"
  local wait_secs
  if [ -n "${SKIP_CODER_AGENTS:-}" ]; then
    printf 'note: Coder Agents wiring skipped (SKIP_CODER_AGENTS is set)\n'
    return 0
  fi
  if [ ! -f "${seeder}" ]; then
    return 0
  fi
  wait_secs="${CODER_AGENTS_WAIT_SECS:-1800}"
  printf 'note: Coder Agents seeder starting in the background (waits up to %ss for the first owner)\n' "${wait_secs}"
  bash "${seeder}" --apply --wait="${wait_secs}" >/dev/null 2>&1 &
  return 0
}

# @function pg_apply_password_entrypoint
# Start the official postgres entrypoint, re-apply POSTGRES_PASSWORD, then wait.
# Globals:
#   POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
# Arguments:
#   $@ - forwarded to docker-entrypoint.sh (the image CMD, usually postgres)
# Outputs:
#   A line when the role password is applied, or a warning when ALTER fails
# Returns:
#   postgres's status
pg_apply_password_entrypoint() {
  local pid=0 role db
  role="${POSTGRES_USER:-postgres}"
  db="${POSTGRES_DB:-${role}}"

  # A compose `entrypoint:` override clears the image CMD, so this wrapper
  # can be exec'd with no arguments. docker-entrypoint.sh then does
  # `exec "$@"` with an empty argv, which is a bash no-op, and the
  # container exits 0 without starting postgres. Default the same way the
  # image entrypoint does: no args, or a leading flag, means postgres.
  if [[ $# -eq 0 ]]; then
    set -- postgres
  elif [[ ${1:0:1} == '-' ]]; then
    set -- postgres "$@"
  fi

  docker-entrypoint.sh "$@" &
  pid=$!
  trap 'kill -TERM "${pid}" 2>/dev/null || true; wait "${pid}"' TERM INT

  if ! pg_wait_ready "${role}" "${pid}"; then
    wait "${pid}"
    return $?
  fi

  if [[ -n ${POSTGRES_PASSWORD:-} ]]; then
    if pg_apply_role_password "${role}" "${POSTGRES_PASSWORD}" "${db}"; then
      printf 'pg-apply-password: aligned role %s with POSTGRES_PASSWORD\n' "${role}"
    else
      printf 'pg-apply-password: ALTER USER %s failed; POSTGRES_PASSWORD was not applied\n' \
        "${role}" >&2
    fi
  fi

  wait "${pid}"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  set -euo pipefail
  pg_apply_password_entrypoint "$@"
fi
