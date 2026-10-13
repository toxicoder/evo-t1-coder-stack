# shellcheck shell=bash
#
# ## coder_api.sh — reach this stack's own control plane (sourced; never executed)
#
# Four scripts (coder-agents.sh and push-template.sh, plus pull-models.sh and
# dashboard-password.sh for their stack probes) need the same reach into the
# compose stack: psql one-offs against Coder's database container, coder-CLI
# and ollama runs inside a service container, and one case that has to
# recreate a service through `docker compose` itself. The knobs below default
# to the real stack and can be overridden per test or per checkout.
#
# Everything here addresses the Docker daemon directly: the stack's containers
# are FOUND by label across whatever projects the daemon holds, and every
# in-container call then runs `docker exec -i <container>` against the name
# found. `docker compose ps`/`exec` with no -p/-f arguments was the old shape
# and it was a bug: a bare compose call first resolves a PROJECT from the
# script's cwd, and under `bazelisk run` that cwd is a runfiles copy under
# Bazel's output base (or execroot) whose directory name is not a compose
# project anywhere. A stack that was up and registered could still read as
# "coder service is not running yet" from that cwd, on every machine including
# the stack host itself — the probe was asking a question about the checkout's
# folder name, not about the daemon. scripts/github-auth.sh already enumerates
# daemon-wide for exactly this reason.
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

# ── Discovery ────────────────────────────────────────────────────────────────

# stack_ps — one bounded, daemon-wide `docker ps`. Prints one
# "<service>|<container-name>" line per running container that carries a
# com.docker.compose.service label; containers without that label (Coder-built
# workspaces, DinD sidecars) come back with an empty service column and no
# caller matches on it. No project scoping by design — see the header.
# @function stack_ps
# List running compose containers as "service|container" lines, across all projects.
# Globals:
#   DOCKER_BIN, PROBE_TIMEOUT
# Arguments:
#   None
# Outputs:
#   One "service|container" line per running container, or docker's own error text
# Returns:
#   0 when the daemon answered; the command's status otherwise
stack_ps() {
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  timeout "${PROBE_TIMEOUT}" ${DOCKER_BIN} ps \
    --format '{{.Label "com.docker.compose.service"}}|{{.Names}}' </dev/null 2>&1
}

# stack_container <ps-body> <service> — pick the container that runs <service>
# out of a stack_ps body: the LAST line whose first |-separated field equals
# the service name exactly, printing only the container name. The whole-field
# comparison is deliberate: a prefix or substring match would let service "db"
# answer from a container labelled "xdb", and container NAMES are never
# consulted, only the label column. Last rather than first match, because
# `docker ps` lists newest first: with the dev stack running beside the
# stable one, the oldest container is the stable stack's, and that is the one
# every caller here means to talk to. A dev-stack experiment that must be
# addressed anyway goes down first (bazelisk run //scripts:dev-stack -- down).
# @function stack_container
# Print the container name running one service, taken from a stack_ps body.
# Globals:
#   None
# Arguments:
#   $1 - stack_ps body; $2 - service name
# Outputs:
#   The container name, or nothing when that service is not running
# Returns:
#   0
stack_container() {
  printf '%s\n' "${1}" | awk -F'|' -v want="${2}" '$1 == want {c = $2} END {print c}'
}

# stack_compose_target <container> — print the compose project and the HOST
# path of the compose file that created <container>, as one
# "<project>|<file>" line (empty file when the daemon does not know). This is
# the only way to address a `docker compose` subcommand from a directory that
# is not the stack's own, which is what makes it safe from `bazelisk run`.
# A container without those labels (docker-run, or a hand-built stack) prints
# just "|", which callers treat as "cannot tell" rather than a guess.
# @function stack_compose_target
# Print "project|compose-file" for one container's compose project, or nothing.
# Globals:
#   DOCKER_BIN, PROBE_TIMEOUT
# Arguments:
#   $1 - container name or id
# Outputs:
#   "project|file" (file may be empty), or docker's own error text
# Returns:
#   0 when the daemon answered; the command's status otherwise
stack_compose_target() {
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  timeout "${PROBE_TIMEOUT}" ${DOCKER_BIN} inspect -f \
    '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}' \
    "${1}" </dev/null 2>&1
}

# ── Wrappers ─────────────────────────────────────────────────────────────────

# psql_sql <sql> — run one statement against Coder's database inside the db
# container, capped, printing stdout AND stderr. ON_ERROR_STOP makes a failed
# statement a non-zero exit instead of a quiet warning, which would otherwise
# surface later as an unexplained auth failure. Returns 1 without touching
# docker when DB_CONTAINER is empty, so a caller that skipped the guards still
# cannot fire an exec at nothing.
# @function psql_sql
# Run one SQL statement inside the db container. Stdout and stderr are both printed.
# Globals:
#   DOCKER_BIN, PROBE_TIMEOUT, DB_CONTAINER, DB_USER, DB_NAME
# Arguments:
#   $1 - SQL
# Outputs:
#   psql's combined output
# Returns:
#   0 on success; the command's status otherwise, or 1 when DB_CONTAINER is unset
psql_sql() {
  [ -n "${DB_CONTAINER:-}" ] || return 1
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  timeout "${PROBE_TIMEOUT}" ${DOCKER_BIN} exec -i "${DB_CONTAINER}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q -c "$1" </dev/null 2>&1
}

# psql_query <sql> — run one single-column query and print ONLY its value,
# whitespace-trimmed. -q -tA suppress the command status and headers that a
# plain -t still prints.
# @function psql_query
# Run one single-column query and print only the trimmed value.
# Globals:
#   DOCKER_BIN, PROBE_TIMEOUT, DB_CONTAINER, DB_USER, DB_NAME
# Arguments:
#   $1 - SQL
# Outputs:
#   The value with whitespace removed
# Returns:
#   0 on success; the command's status otherwise, or 1 when DB_CONTAINER is unset
psql_query() {
  [ -n "${DB_CONTAINER:-}" ] || return 1
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  timeout "${PROBE_TIMEOUT}" ${DOCKER_BIN} exec -i "${DB_CONTAINER}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -q -tAc "$1" </dev/null 2>&1 |
    tr -d '[:space:]'
}

# coder_exec <coder-args...> — run the coder CLI inside the coder container with
# CODER_URL and CODER_SESSION_TOKEN passed through the environment (never via
# argv, where `ps` would show them) and stdin closed, so -i stays parseable and
# this is safe inside a pipe. The caller must have resolved CODER_CONTAINER and
# set CONTAINER_API_URL and session_token first (empty values stay empty rather
# than tripping `set -u`); an empty CODER_CONTAINER returns 1 without exec'ing.
# @function coder_exec
# Run the coder CLI inside the coder container. The token is an env var, not argv.
# Globals:
#   DOCKER_BIN, CODER_CONTAINER, CONTAINER_API_URL, session_token, VERIFY_TIMEOUT, PROBE_TIMEOUT
# Arguments:
#   $@ - coder arguments
# Outputs:
#   The CLI's own output
# Returns:
#   The CLI's status, or 1 when CODER_CONTAINER is unset
coder_exec() {
  [ -n "${CODER_CONTAINER:-}" ] || return 1
  # shellcheck disable=SC2086 # DOCKER_BIN may legitimately hold "sudo docker"
  CODER_URL="${CONTAINER_API_URL:-}" CODER_SESSION_TOKEN="${session_token:-}" \
    timeout "${VERIFY_TIMEOUT:-${PROBE_TIMEOUT}}" ${DOCKER_BIN} exec -i \
    -e CODER_URL -e CODER_SESSION_TOKEN "${CODER_CONTAINER}" \
    coder "$@" </dev/null
}
