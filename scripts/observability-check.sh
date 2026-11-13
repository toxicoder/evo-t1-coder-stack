#!/usr/bin/env bash
#
# ## observability-check.sh - prove the observability bundle collects, ships and shows.
#
# The bundle is six containers behind one compose profile (prometheus, loki, mimir,
# tempo, grafana, alloy). Six green `docker compose ps` lines do not answer the
# question the operator actually has, which is: when I open Grafana, is the data
# there? Four independent things have to be true for that, and each fails in its
# own silent way:
#
#   the keys are the ones compose expects   a Go duration spelled in days is a Mimir
#                                           startup failure, and a blank admin
#                                           password is a Grafana nobody can log into
#   the log source is a real tree            Alloy tails /var/lib/docker/containers.
#                                           Point STACK_DOCKER_LOG_DIR at anything
#                                           else and it tails nothing: no error, no
#                                           log line, an empty Loki forever
#   the services render and run              the profile has to be on and each
#                                           container has to report State.Status=running
#   the data actually flows                  Prometheus has to scrape its own targets
#                                           and push them to Mimir; a red target and a
#                                           failing remote_write are both invisible in
#                                           `ps`, and both leave the dashboard empty
#
# Loki, Mimir, Tempo and Alloy publish no host port at all, so they cannot be
# probed from this shell. They are probed from inside the compose network with a
# one-shot curl container, which is also why none of them needs a healthcheck or a
# shell in its image.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:observability-check
#   bazelisk run //scripts:observability-check -- --env-file ./dev-stack.env
#   bazelisk run //scripts:observability-check -- --timeout 10
#   bazelisk run //scripts:observability-check -- --no-docker
#   bazelisk run //scripts:observability-check -- --help
#
# Options (accepted anywhere in argv):
#   --env-file PATH   dotenv the keys are read from. Default: $ENV_FILE, else
#                     ./.env beside $COMPOSE_FILE, else ./.env
#   --timeout SECS    per-probe curl budget. Default 5.
#   --no-docker       skip every check that shells out to docker
#   -h | --help       print usage, exit 0
#
# Output: the house vocabulary - "== section ==", "-> phase", "ok:", "warning:",
#   "note:", "error:", and a closing "summary: N ok, W warnings, F failed" as the
#   last line of the run.
# Exit codes: 0 with no failures (warnings allowed, and always on the switched-off
#   path, where there is nothing to check); 1 with at least one failure; 2 on a
#   usage error, always answered before the first probe.
#
# A key that is simply absent is a note and not a fault: every key this CLI reads
# has a default in docker-compose.yml, so compose still comes up. A key that is
# present and blank is an operator who wrote the line and left the value out,
# which is a warning, because compose interpolates the empty string.
#
# Related: scripts/search-check.sh (the same prober shape for the search lane),
#   scripts/lib/common.sh (compose_observability_args, the one seam that decides
#   whether the profile is on), docs/dashboard.md (the panels this proves).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# @function resolve_repo_root
# Print the checkout this run reads from: the first candidate holding a
# docker-compose.yml marker. A Bazel sandbox holds a COPY of the tree, so the
# probe is a marker file and never a cwd assumption (project-conventions.md).
# Globals:
#   REPO_ROOT, GITHUB_WORKSPACE, PWD, SELF_DIR
# Arguments:
#   None
# Outputs:
#   The root on stdout, or one complaint line on stderr
# Returns:
#   0 with the root, 5 when no candidate holds the marker
resolve_repo_root() {
  local -a candidates=()
  local candidate
  if [ -n "${REPO_ROOT:-}" ]; then
    candidates+=("${REPO_ROOT}")
  fi
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    candidates+=("${GITHUB_WORKSPACE}")
  fi
  candidates+=("${PWD}" "${SELF_DIR}" "${SELF_DIR}/..")

  for candidate in "${candidates[@]}"; do
    if [ -f "${candidate}/docker-compose.yml" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf 'error: unresolvable repo root: no proven checkout in %s (need docker-compose.yml)\n' \
    "${candidates[*]}" >&2
  return 5
}

# @function find_lib
# Print the path one sourced lib is reachable from: the resolved root first, then
# this script's own directory. Under `bazelisk run //scripts:observability-check`
# both exist inside the runfiles copy, which //scripts:doc_sources makes true.
# Globals:
#   SELF_DIR
# Arguments:
#   $1 - lib file name, relative to the lib directory
#   $2 - resolved repo root, possibly empty
# Outputs:
#   The lib path on stdout, or one complaint line on stderr
# Returns:
#   0 when the lib was found, 1 otherwise
find_lib() {
  local name="$1" root="${2:-}" candidate
  local -a candidates=()
  if [ -n "${root}" ]; then
    candidates+=("${root}/scripts/lib/${name}")
  fi
  candidates+=("${SELF_DIR}/lib/${name}")

  for candidate in "${candidates[@]}"; do
    if [ -f "${candidate}" ]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  printf 'error: %s is not reachable from %s\n' "${name}" "${candidates[*]}" >&2
  return 1
}

REPO_ROOT_RESOLVED="$(resolve_repo_root || true)"
COMMON_LIB="$(find_lib common.sh "${REPO_ROOT_RESOLVED}")" || {
  printf 'error: observability-check cannot run without its helpers: no scripts/lib/common.sh above\n' >&2
  exit 1
}

# shellcheck source=lib/common.sh disable=SC1091
source "${COMMON_LIB}"

# This CLI has no --json: it answers an operator standing at a dashboard, and the
# house JSON vocabulary would send every prose line this prints to stderr.
unset JSON_MODE

# ── knobs ────────────────────────────────────────────────────────────────────

# The six profile-gated services, in the order the bundle comes up. This one list
# is what the render check, the container check and the report all walk.
OBS_SERVICES="prometheus loki mimir tempo grafana alloy"

# The four readiness probes no host port can reach, as service:port/path. The
# pairs are the compose service name and the port that service listens on inside
# the project network; none of them is published to the host on purpose.
OBS_INNER_PROBES=("loki:3100/ready" "mimir:8080/ready" "tempo:3200/ready" "alloy:12345/-/ready")

# The configuration keys, in report order. Every one of them is in .env.example
# and has a default in docker-compose.yml, which is why an absent key is a note.
OBS_CONFIG_KEYS=(
  OBSERVABILITY_ENABLED
  GRAFANA_PORT
  GRAFANA_ADMIN_USER
  GRAFANA_ADMIN_PASSWORD
  PROMETHEUS_PORT
  PROMETHEUS_URL
  PROMETHEUS_RETENTION_TIME
  PROMETHEUS_RETENTION_SIZE
  LOKI_RETENTION_PERIOD
  TEMPO_BLOCK_RETENTION_TIME
  MIMIR_RETENTION_PERIOD
  STACK_DOCKER_LOG_DIR
)

# The keys among them whose value compose interpolates into something that has to
# be there: a port, a credential, a retention window, the log tree. Blank is not
# a valid answer for any of these.
OBS_REQUIRED_KEYS="OBSERVABILITY_ENABLED GRAFANA_PORT GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD \
PROMETHEUS_PORT PROMETHEUS_RETENTION_TIME PROMETHEUS_RETENTION_SIZE LOKI_RETENTION_PERIOD \
TEMPO_BLOCK_RETENTION_TIME MIMIR_RETENTION_PERIOD STACK_DOCKER_LOG_DIR"

# The counter whose non-zero value means the box is collecting but not shipping.
REMOTE_WRITE_COUNTER="prometheus_remote_storage_samples_failed_total"

ENV_FILE_ARG=""
TIMEOUT=5
NO_DOCKER=0
COMPOSE_FILE="${COMPOSE_FILE:-}"
ENV_SRC=""
PROJECT_NAME=""
# Decided by the configuration section: 0 is the switched-off path, where sections
# 3-6 have nothing to check and the run cannot fail.
BUNDLE_ENABLED=1

# @function usage
# Print the flag list and the exit-code contract on stdout.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The usage block on stdout
# Returns:
#   0
usage() {
  cat <<'USAGE'
Usage: bazelisk run //scripts:observability-check -- [OPTIONS]
  --env-file PATH   dotenv the keys are read from. Default: $ENV_FILE, else
                    ./.env beside $COMPOSE_FILE, else ./.env
  --timeout SECS    per-probe curl budget. Default 5.
  --no-docker       skip every check that shells out to docker
  -h | --help       print usage, exit 0

Proves the observability bundle end to end: the keys compose interpolates, the
log tree Alloy tails, the six profile-gated services, their readiness behind
the loopback-only wall, and whether Prometheus is still scraping and shipping.

Loki, Mimir, Tempo and Alloy publish no host port, so their /ready is probed
from inside the compose network with a one-shot curl container. --no-docker
keeps the file-system and configuration checks and turns those probes into
notes, which is the mode to run on a machine with no daemon.

Sections: configuration, log source, compose render, containers, endpoints,
data flow. The last line is always "summary: N ok, W warnings, F failed".

Exit codes: 0 with no failures (or the bundle switched off, where there is
nothing to check); 1 with at least one failure; 2 on a usage error.
USAGE
}

# @function usage_error
# Print one usage complaint plus the usage block on stderr, and exit 2, so a typo
# is never mistaken for a result. Everything on stderr: a caller that pipes the
# happy path's report somewhere still sees only the complaint here.
# Globals:
#   None
# Arguments:
#   $* - the complaint, without the "error: " prefix
# Outputs:
#   The complaint and the usage block on stderr
# Returns:
#   Does not return; exits 2
usage_error() {
  err "$*"
  usage >&2
  exit 2
}

# @function key_requires_value
# Succeed for the keys whose blank value is an operator mistake rather than a
# deliberate fall back to a shipped default. GRAFANA_ADMIN_PASSWORD is on the
# list because a blank one is a Grafana with no admin password at all.
# PROMETHEUS_URL is off it: blank there means "use the loopback default", which
# is what .env.example ships.
# Globals:
#   OBS_REQUIRED_KEYS
# Arguments:
#   $1 - key name
# Outputs:
#   None
# Returns:
#   0 when a blank value is a warning, 1 when it is the documented empty state
key_requires_value() {
  local key="${1:-}" entry
  for entry in ${OBS_REQUIRED_KEYS}; do
    if [[ ${key} == "${entry}" ]]; then
      return 0
    fi
  done
  return 1
}

# @function key_state
# Print absent, blank or value for one key of the env file. env_get cannot tell a
# missing key from a present-and-empty one, and the two mean different things
# here, so the grep probe settles it the same way compose_observability_args
# does. An assignment inside quotes counts as present, and a quoted empty value
# counts as blank.
# Globals:
#   None
# Arguments:
#   $1 - env file
#   $2 - key name
# Outputs:
#   One of absent, blank, value on stdout
# Returns:
#   0, always
key_state() {
  local file="$1" key="$2" value=""
  if [ ! -f "${file}" ] || ! grep -q "^${key}=" "${file}" 2>/dev/null; then
    printf 'absent'
    return 0
  fi
  value="$(env_get "${file}" "${key}")"
  if [ -z "${value}" ]; then
    printf 'blank'
  else
    printf 'value'
  fi
}

# @function resolved_value
# Print the value one key carries for this run: the process environment wins,
# then the env file, then the shipped default. That is compose's own precedence
# for interpolation, and this CLI has to probe the ports compose actually
# published, not the ones the file alone names.
# Globals:
#   ENV_SRC
# Arguments:
#   $1 - key name
#   $2 - default when the key is unset or blank
# Outputs:
#   The value on stdout, with no trailing newline
# Returns:
#   0
resolved_value() {
  local key="$1" default="${2:-}" value=""
  value="${!key:-}"
  if [ -n "${value}" ]; then
    printf '%s' "${value}"
    return 0
  fi
  if [ -f "${ENV_SRC}" ]; then
    value="$(env_get "${ENV_SRC}" "${key}")"
  fi
  if [ -n "${value}" ]; then
    printf '%s' "${value}"
    return 0
  fi
  printf '%s' "${default}"
}

# @function compose_cmd
# Run one docker compose subcommand against this compose file with the profile
# the bundle is gated behind. The profile words come from the one seam that
# decides whether the bundle is on, and travel as two arguments rather than one
# expanded string. -f leads so the printed command reads the way the compose
# documentation writes it.
# Globals:
#   COMPOSE_FILE, ENV_SRC
# Arguments:
#   $1... - the subcommand and its own arguments
# Outputs:
#   The subcommand's stdout and stderr
# Returns:
#   The docker exit status
compose_cmd() {
  local -a prof=()
  read -r -a prof <<<"$(compose_observability_args "${ENV_SRC}")"
  docker compose -f "${COMPOSE_FILE}" "${prof[@]}" "$@"
}

# @function probe_loopback
# Probe one published endpoint over loopback and record the finding. -f makes any
# non-2xx a non-zero exit, so "answered 500" and "answered nothing" both land in
# the same honest bucket, with whatever curl said quoted in the finding.
# Globals:
#   TIMEOUT
# Arguments:
#   $1 - what is being probed, for the finding line
#   $2 - the URL
# Outputs:
#   One ok: or error: line
# Returns:
#   0, always: a dead endpoint is a result here, never an abort
probe_loopback() {
  local what="$1" url="$2" answer="" rc=0
  answer="$(capped_run "${TIMEOUT}" curl -fsS --max-time "${TIMEOUT}" "${url}" 2>&1)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    fail_item "${what} did not answer at ${url}: $(first_line "${answer}") (curl exit ${rc})"
    return 0
  fi
  ok "${what} answers at ${url}"
}

# @function probe_in_network
# Probe an endpoint that publishes no host port, from inside the compose network,
# with a pinned one-shot curl image. The container has no shell in the image being
# probed, so this is the only readiness answer that needs nothing of the target.
# Globals:
#   PROJECT_NAME
# Arguments:
#   $1 - service name; $2 - port; $3 - path
# Outputs:
#   One ok: or error: line
# Returns:
#   0, always
probe_in_network() {
  local service="$1" port="$2" path="$3" url answer="" rc=0 code=""
  url="http://${service}:${port}${path}"
  answer="$(docker run --rm --network "${PROJECT_NAME}_default" curlimages/curl:8.10.1 \
    -s -o /dev/null -w '%{http_code}' "${url}" 2>&1)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    fail_item "${service} could not be probed on ${url}: $(first_line "${answer}") (docker exit ${rc})"
    return 0
  fi
  code="${answer##*$'\n'}"
  case "${code}" in
    2*) ok "${service} is ready: ${code} from ${url}" ;;
    *) fail_item "${service} is not ready: ${code:-nothing} from ${url} (expected 2xx)" ;;
  esac
}

# @function targets_tally
# Print the scrape-target tally of one Prometheus /api/v1/targets body. The record
# separator is the health key itself, so each record ends where one target's
# health begins, and the last "job" in the record before it belongs to that
# target: the labels object is emitted before the health field, so the nearest
# preceding job label is the right one, without a JSON parser.
# Globals:
#   None
# Arguments:
#   $1 - file holding the response body
# Outputs:
#   One `down<TAB>job<TAB>health` line per target that is not up, then one
#   `total<TAB><n><TAB><up>` line; nothing for an empty body
# Returns:
#   0, always
targets_tally() {
  local body="${1:-}"
  [ -s "${body}" ] || return 0
  awk '
    BEGIN { RS = "\"health\":\""; total = 0; ups = 0 }
    NR > 1 {
      status = $0
      sub(/".*/, "", status)
      job = "unknown"
      if (split(prev, parts, "\"job\":\"") > 1) {
        job = parts[split(prev, parts, "\"job\":\"")]
        sub(/".*/, "", job)
      }
      total++
      if (status == "up") { ups++ } else { printf "down\t%s\t%s\n", job, status }
    }
    { prev = $0 }
    END { printf "total\t%d\t%d\n", total, ups }
  ' "${body}"
}

# @function check_configuration
# Read every key the bundle interpolates and say what each one will do. The
# switched-off path is decided here and only here, so one key cannot disagree
# with the profile flag the compose commands carry.
# Globals:
#   ENV_SRC, OBS_CONFIG_KEYS, BUNDLE_ENABLED
# Arguments:
#   None
# Outputs:
#   The configuration section on stdout/stderr
# Returns:
#   0
check_configuration() {
  section "configuration"
  phase "read ${ENV_SRC}"
  if [ ! -f "${ENV_SRC}" ]; then
    note "${ENV_SRC} does not exist: every key falls back to the default compose ships"
  fi

  local key state value
  for key in "${OBS_CONFIG_KEYS[@]}"; do
    state="$(key_state "${ENV_SRC}" "${key}")"
    case "${state}" in
      absent)
        note "${key} is unset: compose ships a default for it"
        ;;
      blank)
        if [ "${key}" = "GRAFANA_ADMIN_PASSWORD" ]; then
          warn "GRAFANA_ADMIN_PASSWORD is blank: Grafana comes up with no admin password until //scripts:bootstrap issues one"
        elif key_requires_value "${key}"; then
          warn "${key} is present but blank: compose interpolates it as the empty string"
        else
          note "${key} is blank: that is its documented empty state"
        fi
        ;;
      value)
        if [ "${key}" = "GRAFANA_ADMIN_PASSWORD" ]; then
          # The value never travels to the report: a health probe that prints a
          # credential is how a credential ends up in a terminal scrollback.
          ok "GRAFANA_ADMIN_PASSWORD is set (value not printed)"
        else
          value="$(env_get "${ENV_SRC}" "${key}")"
          ok "${key}=${value}"
        fi
        ;;
    esac
  done

  # A day suffix is not a shorter way of writing hours: Mimir rejects it and the
  # container crash-loops, which the compose render and the container status both
  # report as something else entirely. Hours only, so say so at the key.
  if [ "$(key_state "${ENV_SRC}" MIMIR_RETENTION_PERIOD)" = "value" ]; then
    value="$(env_get "${ENV_SRC}" MIMIR_RETENTION_PERIOD)"
    if [[ ${value} =~ ^[0-9]+d$ ]]; then
      fail_item "MIMIR_RETENTION_PERIOD=${value} is a startup failure: Mimir takes hours only, so write 2160h rather than 90d"
    fi
  fi

  # Same precedence compose_observability_args uses, so this verdict and the
  # profile flag the compose commands carry cannot come apart.
  local obs_value="true"
  if [ -n "${OBSERVABILITY_ENABLED+set}" ]; then
    obs_value="${OBSERVABILITY_ENABLED}"
  elif [ "$(key_state "${ENV_SRC}" OBSERVABILITY_ENABLED)" = "value" ]; then
    obs_value="$(env_get "${ENV_SRC}" OBSERVABILITY_ENABLED)"
  elif [ "$(key_state "${ENV_SRC}" OBSERVABILITY_ENABLED)" = "blank" ]; then
    obs_value=""
  fi
  if truthy "${obs_value}"; then
    BUNDLE_ENABLED=1
  else
    BUNDLE_ENABLED=0
    note "the bundle is switched off (OBSERVABILITY_ENABLED=${obs_value})"
  fi
}

# @function check_log_source
# Prove the tree Alloy tails is a tree of container logs at all. This is the
# stack's known silent failure: a wrong path tails nothing, Alloy reports itself
# healthy, and Loki stays empty with no error anywhere to read.
# Globals:
#   ENV_SRC, NO_DOCKER
# Arguments:
#   None
# Outputs:
#   The log source section on stdout/stderr
# Returns:
#   0
check_log_source() {
  section "log source"
  local log_dir count
  log_dir="$(resolved_value STACK_DOCKER_LOG_DIR /var/lib/docker/containers)"
  phase "walk ${log_dir} for *-json.log"

  if [ ! -d "${log_dir}" ]; then
    if [ "${NO_DOCKER}" = "1" ]; then
      note "${log_dir} does not exist, and with --no-docker no daemon is expected to have written it: skipped"
    else
      fail_item "STACK_DOCKER_LOG_DIR=${log_dir} is not a directory: Alloy would ship nothing and Loki would stay empty"
    fi
    return 0
  fi
  if [ ! -r "${log_dir}" ] || [ ! -x "${log_dir}" ]; then
    fail_item "STACK_DOCKER_LOG_DIR=${log_dir} is not readable: Alloy runs as root to read these files, and this check cannot"
    return 0
  fi

  count="$(find "${log_dir}" -mindepth 2 -maxdepth 2 -type f -name '*-json.log' -print 2>/dev/null |
    wc -l | tr -d '[:space:]')" || count=""
  case "${count}" in
    '' | *[!0-9]*)
      fail_item "STACK_DOCKER_LOG_DIR=${log_dir} could not be read: Alloy would ship nothing and Loki would stay empty"
      return 0
      ;;
  esac

  if [ "${count}" = "0" ]; then
    fail_item "STACK_DOCKER_LOG_DIR=${log_dir} holds no <id>/<id>-json.log file: Alloy would ship nothing and Loki would stay empty"
    return 0
  fi
  ok "${log_dir} holds ${count} container log file(s) for Alloy to tail"
}

# @function check_compose_render
# Ask compose which services the profile actually renders. A service that never
# renders is a service no `up` will ever start, and the container check would
# only ever report it as missing.
# Globals:
#   COMPOSE_FILE, BUNDLE_ENABLED, NO_DOCKER, OBS_SERVICES
# Arguments:
#   None
# Outputs:
#   The compose render section on stdout/stderr
# Returns:
#   0
check_compose_render() {
  section "compose render"
  if [ "${BUNDLE_ENABLED}" = "0" ]; then
    note "skipped: the bundle is switched off, so there is no profile to render"
    return 0
  fi
  if [ "${NO_DOCKER}" = "1" ]; then
    note "skipped (--no-docker): the render needs the docker CLI"
    return 0
  fi

  local out=""
  phase "docker compose -f ${COMPOSE_FILE} --profile observability config --services"
  if ! out="$(compose_cmd config --services 2>&1)"; then
    fail_item "docker compose could not render ${COMPOSE_FILE}: $(first_line "${out}")"
    return 0
  fi

  local service
  for service in ${OBS_SERVICES}; do
    if printf '%s\n' "${out}" | grep -qx "${service}"; then
      ok "compose renders ${service} under the observability profile"
    else
      fail_item "${service} is not in the observability profile: it is missing from config --services, so no up will ever start it"
    fi
  done
}

# @function check_containers
# Report each service's container by name and state. The name comes from compose,
# never from a guess: nothing in this stack pins container_name, so the name is
# whatever the project's own numbering produced.
# Globals:
#   COMPOSE_FILE, BUNDLE_ENABLED, NO_DOCKER, OBS_SERVICES
# Arguments:
#   None
# Outputs:
#   The containers section on stdout/stderr
# Returns:
#   0
check_containers() {
  section "containers"
  if [ "${BUNDLE_ENABLED}" = "0" ]; then
    note "skipped: the bundle is switched off, so no container is expected to run"
    return 0
  fi
  if [ "${NO_DOCKER}" = "1" ]; then
    note "skipped (--no-docker): container state comes from the daemon"
    return 0
  fi

  local names=""
  phase "docker compose -f ${COMPOSE_FILE} ps --format '{{.Service}} {{.Name}}'"
  if ! names="$(compose_cmd ps --format '{{.Service}} {{.Name}}' 2>&1)"; then
    fail_item "docker compose could not list ${COMPOSE_FILE}: $(first_line "${names}")"
    return 0
  fi

  local service cname status="" reason="" rc=0
  for service in ${OBS_SERVICES}; do
    cname="$(printf '%s\n' "${names}" | awk -v want="${service}" '$1 == want { last = $2 } END { print last }')"
    if [ -z "${cname}" ]; then
      fail_item "${service} has no container in this project: start the bundle with //scripts:dev-stack -- up"
      continue
    fi
    status="$(docker inspect -f '{{.State.Status}}' "${cname}" 2>&1)" || rc=$?
    if [ "${rc}" -ne 0 ]; then
      rc=0
      reason="$(first_line "${status}")"
      fail_item "${service}: ${cname} is not a known container (${reason}): start the bundle with //scripts:dev-stack -- up"
      continue
    fi
    case "${status}" in
      running) ok "${service} container ${cname} is running" ;;
      *) fail_item "${service} container ${cname} reports '${status}', not running: start the bundle with //scripts:dev-stack -- up" ;;
    esac
  done
}

# @function check_endpoints
# Probe what the operator clicks, and what nothing clicks. Prometheus and Grafana
# publish a host port and are probed over loopback; the four behind them are not
# reachable from here at all and go through the compose network.
# Globals:
#   TIMEOUT, BUNDLE_ENABLED, NO_DOCKER, OBS_INNER_PROBES, PROJECT_NAME
# Arguments:
#   None
# Outputs:
#   The endpoints section on stdout/stderr
# Returns:
#   0
check_endpoints() {
  section "endpoints"
  if [ "${BUNDLE_ENABLED}" = "0" ]; then
    note "skipped: the bundle is switched off, so no endpoint is expected to answer"
    return 0
  fi
  if ! has_tool curl; then
    fail_item "curl is not on PATH: no endpoint could be probed, and a check that silently skipped is a check that never ran"
    return 0
  fi

  local prom_port graf_port spec service rest port path
  prom_port="$(resolved_value PROMETHEUS_PORT 9090)"
  graf_port="$(resolved_value GRAFANA_PORT 3005)"

  phase "curl http://127.0.0.1:${prom_port}/-/healthy"
  probe_loopback "prometheus" "http://127.0.0.1:${prom_port}/-/healthy"
  phase "curl http://127.0.0.1:${graf_port}/api/health"
  probe_loopback "grafana" "http://127.0.0.1:${graf_port}/api/health"

  for spec in "${OBS_INNER_PROBES[@]}"; do
    service="${spec%%:*}"
    rest="${spec#*:}"
    port="${rest%%/*}"
    path="/${rest#*/}"
    if [ "${NO_DOCKER}" = "1" ]; then
      note "${service} ${path} skipped (--no-docker): it publishes no host port, so only the project network can answer for it"
      continue
    fi
    phase "docker run --rm --network ${PROJECT_NAME}_default curlimages/curl:8.10.1 http://${service}:${port}${path}"
    probe_in_network "${service}" "${port}" "${path}"
  done
}

# @function check_data_flow
# The question the other five sections cannot answer: is data arriving and going
# somewhere. Targets that are down and samples that fail to reach Mimir are both
# invisible in container status, and both leave the dashboard empty.
# Globals:
#   TIMEOUT, BUNDLE_ENABLED, REMOTE_WRITE_COUNTER, work
# Arguments:
#   None
# Outputs:
#   The data flow section on stdout/stderr
# Returns:
#   0
check_data_flow() {
  section "data flow"
  if [ "${BUNDLE_ENABLED}" = "0" ]; then
    note "skipped: the bundle is switched off, so no data is expected to flow"
    return 0
  fi
  if ! has_tool curl; then
    fail_item "curl is not on PATH: the Prometheus API could not be probed"
    return 0
  fi

  local base prom_port body="${work}/targets.json" metrics="${work}/metrics.txt"
  prom_port="$(resolved_value PROMETHEUS_PORT 9090)"
  base="http://127.0.0.1:${prom_port}"

  phase "curl ${base}/api/v1/targets"
  local err="" tally="" total="0" ups="0" down_lines=""
  if ! err="$(capped_run "${TIMEOUT}" curl -fsS --max-time "${TIMEOUT}" \
    -o "${body}" "${base}/api/v1/targets" 2>&1)"; then
    fail_item "Prometheus did not answer ${base}/api/v1/targets: $(first_line "${err}") - nothing downstream is worth checking until it does"
    return 0
  fi

  tally="$(targets_tally "${body}")"
  total="$(printf '%s\n' "${tally}" | awk -F'\t' '$1 == "total" { print $2 }')"
  ups="$(printf '%s\n' "${tally}" | awk -F'\t' '$1 == "total" { print $3 }')"
  down_lines="$(printf '%s\n' "${tally}" | grep -v '^total' || true)"
  case "${total}" in '' | *[!0-9]*) total="0" ;; esac
  case "${ups}" in '' | *[!0-9]*) ups="0" ;; esac

  if [ "${total}" = "${ups}" ]; then
    ok "prometheus scrape targets: all ${total} up"
  else
    ok "prometheus scrape targets: ${ups} of ${total} up"
    local job status
    while IFS=$'\t' read -r _ job status; do
      [ -n "${job}" ] || continue
      warn "prometheus target job '${job}' reports '${status}', not up: its panel will be empty"
    done <<<"${down_lines}"
  fi

  phase "curl ${base}/metrics"
  if ! err="$(capped_run "${TIMEOUT}" curl -fsS --max-time "${TIMEOUT}" \
    -o "${metrics}" "${base}/metrics" 2>&1)"; then
    fail_item "Prometheus did not answer ${base}/metrics: $(first_line "${err}")"
    return 0
  fi

  if ! grep -q "${REMOTE_WRITE_COUNTER}" "${metrics}" 2>/dev/null; then
    warn "prometheus exposes no ${REMOTE_WRITE_COUNTER}: nothing is configured to ship to Mimir, so check the remote_write block"
    return 0
  fi
  local failed
  failed="$(awk -v name="${REMOTE_WRITE_COUNTER}" '$1 ~ "^" name "(\\{|$)" { sum += $2 } END { printf "%d", sum }' "${metrics}")"
  case "${failed}" in '' | *[!0-9]*) failed="0" ;; esac
  if [ "${failed}" != "0" ]; then
    warn "${REMOTE_WRITE_COUNTER}=${failed}: Prometheus is collecting but Mimir is not accepting its samples"
  else
    ok "prometheus remote_write: no failed samples to Mimir"
  fi
}

# @function finish
# Close the run: the summary as the last line of output, and the exit code that
# answers the same question the report just answered.
# Globals:
#   SUMMARY_FAIL, BUNDLE_ENABLED
# Arguments:
#   None
# Outputs:
#   The summary line on stdout
# Returns:
#   Nothing: exits 0 on a clean or switched-off run, 1 on any failure
finish() {
  # The grammar pins the summary as the LAST line, so the recorded items are not
  # re-listed beneath it: every error was already printed where it happened.
  # shellcheck disable=SC2034 # summary() in scripts/lib/common.sh is the reader
  SUMMARY_FAIL_ITEMS=""
  summary
  if [ "${BUNDLE_ENABLED}" = "0" ]; then
    # A switched-off bundle has nothing left to fail: the operator said so in the
    # one key that decides it, and every container this CLI would blame is off
    # because they were asked to be.
    exit 0
  fi
  if [ "${SUMMARY_FAIL:-0}" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file)
      [ "$#" -ge 2 ] || usage_error "unknown option: $1 (--env-file needs a path)"
      ENV_FILE_ARG="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || usage_error "unknown option: $1 (--timeout needs a value in seconds)"
      TIMEOUT="$2"
      shift 2
      ;;
    --no-docker)
      NO_DOCKER=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown option: $1"
      ;;
  esac
done

case "${TIMEOUT}" in '' | *[!0-9]* | 0) usage_error "unknown option: --timeout needs a whole number of seconds, got '${TIMEOUT}'" ;; esac

if [ -z "${COMPOSE_FILE}" ]; then
  COMPOSE_FILE="${REPO_ROOT_RESOLVED:-${PWD}}/docker-compose.yml"
fi
if [ -n "${ENV_FILE_ARG}" ]; then
  ENV_SRC="${ENV_FILE_ARG}"
elif [ -n "${ENV_FILE:-}" ]; then
  ENV_SRC="${ENV_FILE}"
else
  ENV_SRC="$(dirname "${COMPOSE_FILE}")/.env"
fi
# The network every in-network probe joins: compose names it after the project,
# and the project is named after the directory the compose file sits in.
PROJECT_NAME="$(basename "$(dirname "${COMPOSE_FILE}")")"

# One scratch directory per run for the response bodies, removed on every exit
# path. Nothing here is written into the repo, which is what lets this run inside
# a Bazel sandbox or a read-only checkout.
work="$(mktemp -d 2>/dev/null || true)"
[ -n "${work}" ] || usage_error "unknown option: could not create a scratch directory for the probe bodies"
trap 'rm -rf "${work}"' EXIT

check_configuration
check_log_source
check_compose_render
check_containers
check_endpoints
check_data_flow
finish
