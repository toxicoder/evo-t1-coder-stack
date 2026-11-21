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
# The four host exporters the same profile publishes on loopback - node_exporter,
# cAdvisor, blackbox_exporter, Alertmanager - are probed too, and against a
# different bar than the six services above: a container that started is not an
# exporter that answers, an exporter that answers is not one that exposes the
# series the panel queries, and a blackbox module Prometheus never loaded stays
# invisible until the alert it should have fired goes quiet.
#
# Two more things sit between a green `ps` and the screen the operator opens, and
# both fail silently: a rule file prometheus.yml names that Prometheus never
# loaded makes every alert in it dead with nothing in any log to say so, and a
# dashboard JSON the file provider refused to import is simply not a screen. Both
# are answered from the two APIs that know - /api/v1/rules and /api/search - and
# both treat "the bundle is not up" as the legitimate state it is, because the
# whole thing rides the observability compose profile.
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

# The ten profile-gated services, in the order the bundle comes up. This one list
# is what the render check, the container check and the report all walk. The four
# exporters are in it because they ride the same profile
# (docker-compose.yml:1098,1133,1168,1187) and a `ps` that omits them is a run
# that cannot see a missing node_exporter; they carry no in-network probe, since
# each is asked of its own published loopback port in the exporters section.
OBS_SERVICES="prometheus loki mimir tempo grafana alloy node_exporter cadvisor blackbox_exporter alertmanager"

# The four readiness probes no host port can reach, as service:port/path. The
# pairs are the compose service name and the port that service listens on inside
# the project network; none of them is published to the host on purpose.
OBS_INNER_PROBES=("loki:3100/ready" "mimir:8080/ready" "tempo:3200/ready" "alloy:12345/-/ready")

# The four host exporters the profile publishes on loopback, as
# name:env-key:default-port:metric-prefix. The port keys and their defaults are
# the compose interpolations (docker-compose.yml:1116,1150,1168,1203), and the
# metric prefix is one series that family must expose for the exporter to count
# as configured: node_filefd_allocated and container_last_seen are on by default
# (ctx/L0.md:76,80), and the two prefixes catch the exporter's own series without
# betting the verdict on one gauge name.
OBS_HOST_EXPORTERS=(
  "node_exporter:OBS_NODE_EXPORTER_PORT:9101:node_filefd_allocated"
  "cadvisor:OBS_CADVISOR_PORT:9290:container_last_seen"
  "blackbox_exporter:OBS_BLACKBOX_PORT:9115:blackbox_exporter_"
  "alertmanager:OBS_ALERTMANAGER_PORT:9093:alertmanager_"
)

# The modules observability/blackbox/blackbox.yml ships and the scrape job that
# passes each one (observability/prometheus/prometheus.yml:164,184), as
# module:job. Each is asked of the prober directly, so a module that never loaded
# is answered here rather than by an alert that never fires.
OBS_BLACKBOX_PROBES=("spark_health:blackbox-spark" "spark_models:blackbox-spark-models")

# The scrape jobs that only exist if prometheus.yml still collects the four
# exporters (observability/prometheus/prometheus.yml:124,133,164,184,200). An
# exporter that answers its own /metrics and is named by none of these is
# collected by nobody.
OBS_SCRAPED_JOBS="node_exporter cadvisor blackbox-spark blackbox-spark-models alertmanager"

# The config this CLI reads two more facts out of, by path under the resolved
# root rather than by copying them here, so the bundle stays the single place
# that says what it ships: the rule files prometheus.yml's rule_files: block
# names (observability/prometheus/prometheus.yml:43-46), and the dashboard JSON
# the file provider loads, which docker-compose.yml:1019 binds read-only from
# this directory to /var/lib/grafana/dashboards.
OBS_PROMETHEUS_YML="observability/prometheus/prometheus.yml"
OBS_DASHBOARD_DIR="observability/grafana/dashboards"

# The file-SD document the three Spark jobs read their targets from
# (observability/prometheus/prometheus.yml:149,171,195), which compose binds
# read-only into Prometheus at /etc/spark-targets (docker-compose.yml:869), a
# sibling of the /etc/prometheus bind: runc cannot mkdir a nested mountpoint the
# read-only parent does not carry. Generated, so absence is an unenrolled fleet.
OBS_SPARK_TARGETS_JSON="observability/spark-targets/sparks.json"

# The Grafana verb that lists the provisioned dashboards. type=dash-db is the
# set the file provider owns, which is the set this run can hold git against;
# a screen someone hand-created in the browser is nobody's contract.
OBS_DASHBOARD_SEARCH="api/search?type=dash-db"

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
log tree Alloy tails, the ten profile-gated services, their readiness behind
the loopback-only wall, whether Prometheus is still scraping and shipping, the
rule files it loaded, and the dashboards Grafana registered.

Loki, Mimir, Tempo and Alloy publish no host port, so their /ready is probed
from inside the compose network with a one-shot curl container. --no-docker
keeps the file-system and configuration checks and turns those probes into
notes, which is the mode to run on a machine with no daemon.

Sections: configuration, log source, compose render, containers, endpoints,
data flow, exporters, rules, dashboards. The last line is always
"summary: N ok, W warnings, F failed".

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

# @function fetch_with_code
# Fetch one URL into a file and report its HTTP status code, keeping curl's own
# complaint for the caller to quote. This is probe_loopback's question asked the
# other way: no -f, because a 404 and a refused socket are two different findings
# here and -f would fold them into one non-zero exit. curl's stderr goes to a file
# rather than being merged into stdout, so the code stays one clean token.
# Globals:
#   TIMEOUT, work, FETCH_CODE, FETCH_ERR
# Arguments:
#   $1 - the URL
#   $2 - file to write the response body to
# Outputs:
#   The body in $2; the status code in FETCH_CODE and curl's first complaint line
#   in FETCH_ERR (empty when curl never got that far)
# Returns:
#   curl's exit status, so 7 is "nothing was listening"
fetch_with_code() {
  local url="$1" body="$2" rc=0
  FETCH_CODE=""
  FETCH_ERR=""
  capped_run "${TIMEOUT}" curl -sS --max-time "${TIMEOUT}" -o "${body}" \
    -w '%{http_code}' "${url}" >"${work}/http-code" 2>"${work}/http-err" || rc=$?
  FETCH_CODE="$(sed -n '1p' "${work}/http-code" 2>/dev/null || true)"
  FETCH_ERR="$(sed -n '1p' "${work}/http-err" 2>/dev/null || true)"
  return "${rc}"
}

# @function refused
# Succeed when curl's exit and complaint say the socket was refused rather than
# merely broken, which is the one answer that means the container is not running
# at all. -sS keeps curl's message, so "Connection refused" is there to match.
# Globals:
#   None
# Arguments:
#   $1 - curl's exit status; $2 - curl's first complaint line
# Outputs:
#   None
# Returns:
#   0 when nothing is listening on that port, 1 for every other curl failure
refused() {
  local rc="${1:-}" err="${2:-}"
  if [[ ${rc} == "7" || ${err} == *"Connection refused"* || ${err} == *"Couldn't connect"* ]]; then
    return 0
  fi
  return 1
}

# @function probe_exporter
# Probe one host exporter's /metrics and say which of the three shapes it is in,
# because the three want three different fixes: a refused socket means the
# container never started; a 404 means something else holds that port, or this
# probe asks a path the binary has never served; and a 200 with no expected
# family means the exporter is up with the collector that serves it switched off
# (node_exporter --collector.processes is ctx/L0.md:75's example of exactly that).
# Severity follows what this CLI already does with Prometheus: an endpoint the
# profile is supposed to have published that does not answer is a failure, the way
# probe_loopback reports it, while a service that answers and is merely
# misconfigured is a warning, the way a red scrape target already is.
# Globals:
#   TIMEOUT, work
# Arguments:
#   $1 - exporter name; $2 - published port; $3 - path; $4 - metric family prefix
# Outputs:
#   One ok:, warning: or error: line, and its phase line
# Returns:
#   0, always: a dead exporter is a result here, never an abort
probe_exporter() {
  local what="$1" port="$2" path="$3" metric="$4"
  local url="http://127.0.0.1:${port}${path}" body="${work}/${what}.metrics" rc=0
  phase "curl ${url}"
  fetch_with_code "${url}" "${body}" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    if refused "${rc}" "${FETCH_ERR}"; then
      fail_item "${what} is not listening on 127.0.0.1:${port}: connection refused, so its container is not running - start the bundle with //scripts:dev-stack -- up"
    else
      fail_item "${what} did not answer at ${url}: ${FETCH_ERR:-no answer} (curl exit ${rc})"
    fi
    return 0
  fi
  case "${FETCH_CODE}" in
    404)
      fail_item "${what} answered 404 at ${url}: something holds ${port} but serves no ${path}, so the published port belongs to another service or the path is wrong"
      ;;
    2??)
      if grep -qE "^${metric}" "${body}" 2>/dev/null; then
        ok "${what} answers at ${url} and exposes ${metric} series"
      else
        warn "${what} answered 200 at ${url} but exposes no series starting with ${metric}: the exporter is up and misconfigured, or the collector that serves it is off"
      fi
      ;;
    *)
      fail_item "${what} answered ${FETCH_CODE:-nothing} at ${url}: expected 200"
      ;;
  esac
}

# @function probe_prober
# Ask blackbox_exporter to run one probe end to end and report what it answered.
# Prometheus asks the prober the same way, so this is the only check that shows a
# module that never loaded while the bundle is otherwise green: an unknown module
# is answered 4xx with blackbox's own "not found" body, which is not a red target
# and must not be reported as one. A probe that came back red IS the prober
# working, so probe_success 0 is a warning that names its target rather than a
# failure of the prober.
# Globals:
#   TIMEOUT, work
# Arguments:
#   $1 - module name; $2 - prober port; $3 - target the prober should reach
# Outputs:
#   One ok:, warning: or error: line, and its phase line
# Returns:
#   0, always
probe_prober() {
  local module="$1" port="$2" target="$3"
  local url="http://127.0.0.1:${port}/probe?module=${module}&target=${target}"
  local body="${work}/probe-${module}.txt" rc=0 success="" status=""
  phase "curl ${url}"
  fetch_with_code "${url}" "${body}" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    if refused "${rc}" "${FETCH_ERR}"; then
      fail_item "blackbox_exporter is not listening on 127.0.0.1:${port}: connection refused, so no probe of any module can have run"
    else
      fail_item "blackbox_exporter could not be asked for the ${module} probe at ${url}: ${FETCH_ERR:-no answer} (curl exit ${rc})"
    fi
    return 0
  fi
  case "${FETCH_CODE}" in
    404)
      fail_item "blackbox_exporter answered 404 at ${url}: something holds ${port} but serves no /probe, so the published port belongs to another service"
      ;;
    2??)
      success="$(awk '$1 == "probe_success" { print $2; exit }' "${body}" 2>/dev/null)"
      status="$(awk '$1 == "probe_http_status_code" { print $2; exit }' "${body}" 2>/dev/null)"
      case "${success}" in
        1) ok "blackbox_exporter ran the ${module} probe of ${target}: probe_success 1" ;;
        0) warn "blackbox_exporter ran the ${module} probe of ${target} and it came back red: probe_success 0, probe_http_status_code ${status:-none} - the module loaded, the target does not answer the way it expects" ;;
        *) warn "blackbox_exporter answered 200 at ${url} but sent no probe_success series: the prober is up and probing nothing" ;;
      esac
      ;;
    *)
      local detail=""
      detail="$(sed -n '1p' "${body}" 2>/dev/null || true)"
      if grep -qi 'not found' "${body}" 2>/dev/null; then
        fail_item "blackbox_exporter does not know the module ${module}: ${FETCH_CODE} from ${url} - ${detail}"
      else
        fail_item "blackbox_exporter refused the ${module} probe: ${FETCH_CODE:-nothing} from ${url} - ${detail}"
      fi
      ;;
  esac
}

# @function targets_tally
# Print the scrape-target tally of one Prometheus /api/v1/targets body. The record
# separator is the health key itself, so each record ends where one target's
# health begins, and the last "job" in the record before it belongs to that
# target: the labels object is emitted before the health field, so the nearest
# preceding job label is the right one, without a JSON parser. The lastError is
# read from that same record by the same rule, because Prometheus writes it
# immediately before health - it is the only place the cause of a red target
# exists, and a tally that dropped it left the caller guessing at one.
# Globals:
#   None
# Arguments:
#   $1 - file holding the response body
# Outputs:
#   Exactly four TAB-separated fields on every line, in this order:
#   `down<TAB>job<TAB>health<TAB>lastError` per target that is not up, then one
#   `total<TAB><n><TAB><up><TAB>-` line. The fourth field is the target's own
#   lastError text, or `-` when it carries none and on the total line, so the
#   caller never reads a missing column as an empty one. A tab, CR or LF inside
#   that text is folded to a space, so one target is always exactly one line.
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
      error = ""
      if (split(prev, bits, "\"lastError\":\"") > 1) {
        error = bits[split(prev, bits, "\"lastError\":\"")]
        sub(/".*/, "", error)
        gsub(/[ \t\r\n]/, " ", error)
      }
      total++
      if (status == "up") { ups++ }
      else { printf "down\t%s\t%s\t%s\n", job, status, (error == "" ? "-" : error) }
    }
    { prev = $0 }
    END { printf "total\t%d\t%d\t-\n", total, ups }
  ' "${body}"
}

# @function rule_files_from
# Print the rule files one prometheus.yml tells Prometheus to load: every entry
# of its rule_files: list, and nothing past the block. Read from the file rather
# than repeated here, so a fourth rule file added to the config is checked by
# this CLI without a second edit anywhere.
# Globals:
#   None
# Arguments:
#   $1 - the prometheus.yml to read
# Outputs:
#   One rule file path per line on stdout, as prometheus.yml writes it; nothing
#   when the file has no rule_files block
# Returns:
#   0, always
rule_files_from() {
  local file="${1:-}"
  [ -r "${file}" ] || return 0
  awk '
    /^rule_files[[:space:]]*:/ { inblock = 1; next }
    inblock && /^[^[:space:]#]/ { inblock = 0 }
    inblock && /^[[:space:]]*-/ {
      entry = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", entry)
      sub(/[[:space:]]*$/, "", entry)
      sub(/^"/, "", entry)
      sub(/"$/, "", entry)
      if (entry != "") { print entry }
    }
  ' "${file}"
}

# @function rules_tally
# Print one `file<TAB>groups<TAB>rules` row per rule file in a Prometheus
# /api/v1/rules body. The record separator is the file key Prometheus writes into
# every group, so one record is one group, and the rules inside it are counted by
# their health keys: every rule carries exactly one health field and a group
# carries none, which is what makes the count right without a JSON parser, the
# same way targets_tally reads the target list.
# Globals:
#   None
# Arguments:
#   $1 - file holding the response body
# Outputs:
#   One row per rule file that loaded, in the order they first appear; nothing
#   for an empty body
# Returns:
#   0, always
rules_tally() {
  local body="${1:-}"
  [ -s "${body}" ] || return 0
  awk '
    BEGIN { RS = "\"file\":\""; n = 0 }
    NR > 1 {
      file = $0
      sub(/".*/, "", file)
      rules = split($0, pieces, "\"health\":\"") - 1
      if (!(file in groups)) { n++; order[n] = file; groups[file] = 0; rulecount[file] = 0 }
      groups[file]++
      rulecount[file] += rules
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%d\t%d\n", order[i], groups[order[i]], rulecount[order[i]] }
  ' "${body}"
}

# @function dashboard_fields
# Print one `uid<TAB>title` row for one dashboard JSON. Only the two top-level
# keys count: the shipped files indent two spaces per level, and a `title` three
# levels down is a panel's name, not the page's.
# Globals:
#   None
# Arguments:
#   $1 - the dashboard file
# Outputs:
#   `uid<TAB>title` on stdout, with either field empty when the file omits it
# Returns:
#   0, always
dashboard_fields() {
  awk '
    /^  "uid"[[:space:]]*:/   { uid = $0; sub(/^[^:]*:[[:space:]]*"/, "", uid); sub(/".*/, "", uid) }
    /^  "title"[[:space:]]*:/ { title = $0; sub(/^[^:]*:[[:space:]]*"/, "", title); sub(/".*/, "", title) }
    END { printf "%s\t%s\n", uid, title }
  ' "${1:-}" 2>/dev/null
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
#   TIMEOUT, BUNDLE_ENABLED, REMOTE_WRITE_COUNTER, work, ENV_SRC
#   REPO_ROOT_RESOLVED, PWD, OBS_PROMETHEUS_YML, OBS_SPARK_TARGETS_JSON
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

  # An enrolled fleet whose file-SD document never landed is indistinguishable,
  # from above, from a stack that deliberately runs no Sparks: the three Spark jobs
  # load no target and every section stays quiet. The flag is read the way
  # scripts/spark-monitor.sh:212 reads it, so the two CLIs never disagree about
  # whether the operator asked for Sparks. It is an on-disk fact, so it is read
  # ahead of the probes: a bundle that is down must not hide it.
  local spark_root spark_targets
  spark_root="${REPO_ROOT_RESOLVED:-${PWD}}"
  spark_targets="${spark_root}/${OBS_SPARK_TARGETS_JSON}"
  if truthy "$(resolved_value SPARK_MONITOR_ENABLED false)" &&
    [ ! -e "${spark_targets}" ]; then
    note "${spark_targets} does not exist: Prometheus reads its Spark targets from it, via the file_sd_configs in ${OBS_PROMETHEUS_YML} (job spark-node :149, blackbox-spark :171, blackbox-spark-models :195), and compose binds that directory into Prometheus at /etc/spark-targets - write it with 'bazelisk run //scripts:spark-monitor -- --targets'"
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
    local job status last_error
    while IFS=$'\t' read -r _ job status last_error; do
      [ -n "${job}" ] || continue
      warn "prometheus target job '${job}' reports '${status}', not up: lastError '${last_error}' - its panel will be empty"
      # What prom/prometheus:v3.16.0 records for one red litellm target is at
      # least three different things: an unreadable bearer file, a bearer the
      # proxy rejects with a 401, and a proxy that is not listening at all. Only
      # the first two are the bearer file, so the pointer below follows the
      # lastError instead of naming a cause this CLI never read. Metrics auth
      # stays on either way, so it is never offered as the fix.
      if [ "${job}" = "litellm" ]; then
        case "${last_error}" in
          *401* | *Unauthorized* | *"authorization credentials"* | *"credentials file"*)
            warn "that lastError is the bearer, not the proxy: check that /etc/prometheus-secrets/litellm_token exists in the prometheus container, and that compose rendered configs.litellm_metrics_token from the same LITELLM_MASTER_KEY the proxy has - metrics auth stays on"
            ;;
          *"connection refused"* | *"connection reset"* | *"no route to host"* | *"no such host"* | *"i/o timeout"* | *"dial tcp"*)
            warn "that lastError is the proxy itself, not the bearer file: litellm has to be up and answering litellm:4000 on the project network before any token is worth reading into"
            ;;
          *)
            warn "the lastError above is the only cause this CLI has for the litellm scrape: it dials litellm:4000 on the project network, so start there rather than at the bearer file"
            ;;
        esac
      fi
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

# @function check_exporters
# The four exporters the profile publishes on the host's loopback, and the two
# questions no other section of this run answers: does each one expose the series
# the panel queries, and does Prometheus still collect it. The job names come from
# prometheus.yml, so an exporter that answers its own /metrics while no job names
# it is reported as what it is - collected by nobody - instead of being counted
# green by the four probes above it.
# Globals:
#   TIMEOUT, BUNDLE_ENABLED, work, ENV_SRC
#   OBS_HOST_EXPORTERS, OBS_BLACKBOX_PROBES, OBS_SCRAPED_JOBS
# Arguments:
#   None
# Outputs:
#   The exporters section on stdout/stderr
# Returns:
#   0
check_exporters() {
  section "exporters"
  if [ "${BUNDLE_ENABLED}" = "0" ]; then
    note "skipped: the bundle is switched off, so no exporter port is expected to be bound"
    return 0
  fi
  if ! has_tool curl; then
    fail_item "curl is not on PATH: no exporter could be probed, and a check that silently skipped is a check that never ran"
    return 0
  fi

  local spec name port_key default_port metric
  for spec in "${OBS_HOST_EXPORTERS[@]}"; do
    IFS=':' read -r name port_key default_port metric <<<"${spec}"
    probe_exporter "${name}" "$(resolved_value "${port_key}" "${default_port}")" "/metrics" "${metric}"
  done

  # Alertmanager's own readiness verb, asked the way prometheus and grafana are.
  local am_port bb_port prom_port target probe
  am_port="$(resolved_value OBS_ALERTMANAGER_PORT 9093)"
  phase "curl http://127.0.0.1:${am_port}/-/ready"
  probe_loopback "alertmanager" "http://127.0.0.1:${am_port}/-/ready"

  # The prober probes what nothing scrapes, so it gets asked for a probe of a URL
  # that is up whenever the bundle is, by service name, the way Prometheus itself
  # reaches it. The verdict this reports is about the prober, not the target.
  bb_port="$(resolved_value OBS_BLACKBOX_PORT 9115)"
  prom_port="$(resolved_value PROMETHEUS_PORT 9090)"
  target="http://prometheus:${prom_port}/-/healthy"
  for probe in "${OBS_BLACKBOX_PROBES[@]}"; do
    probe_prober "${probe%%:*}" "${bb_port}" "${target}"
  done

  # The target list the data flow section already fetched is the only proof that
  # somebody collects these: a green /metrics with no job is a series nobody reads.
  local targets="${work}/targets.json" job
  if [ ! -s "${targets}" ]; then
    note "the scrape jobs were not checked: Prometheus never answered /api/v1/targets, so its target list is unknown"
    return 0
  fi
  for job in ${OBS_SCRAPED_JOBS}; do
    if grep -q "\"job\":\"${job}\"" "${targets}" 2>/dev/null; then
      ok "prometheus collects the ${job} job"
    else
      warn "prometheus collects no ${job} job: the exporter answers its own /metrics and nobody scrapes it, so its panel will be empty"
    fi
  done
}

# @function check_rules
# Ask Prometheus which rule files it actually loaded, and report one line per
# file its own rule_files: block names. A file that is in git, named by the
# config, and absent from /api/v1/rules loads nowhere: every alert in it is
# silent, and `docker compose ps` stays green while that is true. A file that
# loads with no rule in it is the same silence wearing a 200.
#
# Severity follows the profile, not the endpoint: the whole bundle is gated
# behind observability, so a Prometheus that is simply not up is a state the
# operator chose and this run says so as a warning, the way a red scrape target
# is one. The endpoints section keeps the hard failure for a service the
# profile was asked to run and that will not answer.
# Globals:
#   TIMEOUT, BUNDLE_ENABLED, work, REPO_ROOT_RESOLVED, PWD
#   OBS_PROMETHEUS_YML
# Arguments:
#   None
# Outputs:
#   The rules section on stdout/stderr
# Returns:
#   0
check_rules() {
  section "rules"
  if [ "${BUNDLE_ENABLED}" = "0" ]; then
    note "skipped: the bundle is switched off, so no rule file is expected to be loaded"
    return 0
  fi
  if ! has_tool curl; then
    fail_item "curl is not on PATH: the Prometheus rules API could not be probed, and a check that silently skipped is a check that never ran"
    return 0
  fi

  local root prom_yml entry
  root="${REPO_ROOT_RESOLVED:-${PWD}}"
  prom_yml="${root}/${OBS_PROMETHEUS_YML}"
  if [ ! -r "${prom_yml}" ]; then
    warn "${prom_yml} is not readable: the rule_files list is unknown, so no rule file is proven loaded"
    return 0
  fi

  local -a want=()
  while IFS= read -r entry; do
    [ -n "${entry}" ] && want+=("${entry}")
  done <<<"$(rule_files_from "${prom_yml}")"
  if [ "${#want[@]}" = "0" ]; then
    note "${OBS_PROMETHEUS_YML} names no rule_files: there is nothing for Prometheus to load, so no alert can fire from any of them"
    return 0
  fi

  local base prom_port body="${work}/rules.json" err="" rc=0
  prom_port="$(resolved_value PROMETHEUS_PORT 9090)"
  base="http://127.0.0.1:${prom_port}"

  phase "curl ${base}/api/v1/rules"
  err="$(capped_run "${TIMEOUT}" curl -fsS --max-time "${TIMEOUT}" \
    -o "${body}" "${base}/api/v1/rules" 2>&1)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    if refused "${rc}" "${err}"; then
      warn "no Prometheus is listening on 127.0.0.1:${prom_port}: the bundle runs under the observability compose profile, so it may simply not be up - start it with //scripts:dev-stack -- up, and until it is, none of the ${#want[@]} rule file(s) can be proven loaded"
    else
      warn "Prometheus did not answer ${base}/api/v1/rules: $(first_line "${err}") (curl exit ${rc}) - the ${#want[@]} rule file(s) prometheus.yml names are not proven loaded"
    fi
    return 0
  fi

  local tally groups rules
  tally="$(rules_tally "${body}")"
  for entry in "${want[@]}"; do
    groups="$(printf '%s\n' "${tally}" | awk -F'\t' -v want="${entry}" '$1 == want { print $2; exit }')"
    rules="$(printf '%s\n' "${tally}" | awk -F'\t' -v want="${entry}" '$1 == want { print $3; exit }')"
    if [ -z "${groups}" ]; then
      fail_item "${entry} is named by ${OBS_PROMETHEUS_YML} but Prometheus loaded no group from it: every alert in that file is silent - check the path against the bind that puts it under /etc/prometheus"
    elif [ "${rules}" = "0" ]; then
      fail_item "${entry} loaded ${groups} group(s) holding 0 rules: the file parses and ships nothing, so no alert can ever fire from it"
    else
      ok "${entry} is loaded: ${groups} group(s), ${rules} rule(s)"
    fi
  done
}

# @function check_dashboards
# Prove every dashboard in git is a screen in Grafana. The file provider imports
# what it likes out of the bound directory and says nothing when it refuses one,
# so an unimported dashboard is not a broken panel and not a log line: it is just
# one screen short of the folder, forever. The on-disk set is walked here and
# compared against one /api/search answer, so a dashboard git ships and Grafana
# never registered is named by its own uid.
# Globals:
#   TIMEOUT, BUNDLE_ENABLED, work, REPO_ROOT_RESOLVED, PWD
#   OBS_DASHBOARD_DIR, OBS_DASHBOARD_SEARCH
# Arguments:
#   None
# Outputs:
#   The dashboards section on stdout/stderr
# Returns:
#   0
check_dashboards() {
  section "dashboards"
  if [ "${BUNDLE_ENABLED}" = "0" ]; then
    note "skipped: the bundle is switched off, so no dashboard is expected to be registered"
    return 0
  fi
  if ! has_tool curl; then
    fail_item "curl is not on PATH: the Grafana dashboard API could not be probed, and a check that silently skipped is a check that never ran"
    return 0
  fi

  local root dir file
  root="${REPO_ROOT_RESOLVED:-${PWD}}"
  dir="${root}/${OBS_DASHBOARD_DIR}"
  if [ ! -d "${dir}" ] || [ ! -r "${dir}" ]; then
    warn "${dir} is not a readable directory: the shipped dashboards are invisible to this run, so none of them is proven registered"
    return 0
  fi

  local -a files=()
  for file in "${dir}"/*.json; do
    [ -f "${file}" ] || continue
    files+=("${file}")
  done
  if [ "${#files[@]}" = "0" ]; then
    fail_item "${dir} holds no *.json: Grafana's file provider has nothing to load, so the dashboard folder would be empty"
    return 0
  fi

  local base graf_port body="${work}/search.json" err="" rc=0 user
  graf_port="$(resolved_value GRAFANA_PORT 3005)"
  base="http://127.0.0.1:${graf_port}"
  local -a auth=()
  user="$(resolved_value GRAFANA_ADMIN_USER admin)"
  if [ -n "${user}" ]; then
    # The credential travels to curl and nowhere else: the value never joins a
    # report line, the way GRAFANA_ADMIN_PASSWORD never joins the configuration
    # section's ok:.
    auth=(-u "${user}:$(resolved_value GRAFANA_ADMIN_PASSWORD '')")
  fi

  phase "curl ${base}/${OBS_DASHBOARD_SEARCH}"
  err="$(capped_run "${TIMEOUT}" curl -fsS --max-time "${TIMEOUT}" "${auth[@]}" \
    -o "${body}" "${base}/${OBS_DASHBOARD_SEARCH}" 2>&1)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    if refused "${rc}" "${err}"; then
      warn "no Grafana is listening on 127.0.0.1:${graf_port}: the bundle runs under the observability compose profile, so it may simply not be up - start it with //scripts:dev-stack -- up, and until it is, none of the ${#files[@]} dashboard file(s) in ${OBS_DASHBOARD_DIR} is proven registered"
    else
      warn "Grafana did not answer ${base}/${OBS_DASHBOARD_SEARCH}: $(first_line "${err}") (curl exit ${rc}) - the ${#files[@]} dashboard file(s) in ${OBS_DASHBOARD_DIR} are therefore unproven"
    fi
    return 0
  fi

  local uid title name
  for file in "${files[@]}"; do
    name="$(basename "${file}")"
    IFS=$'\t' read -r uid title <<<"$(dashboard_fields "${file}")"
    if [ -z "${uid}" ]; then
      warn "${name} names no top-level uid: this run cannot ask Grafana for it, so it is not proven registered"
    elif grep -q "\"uid\":\"${uid}\"" "${body}" 2>/dev/null; then
      ok "${uid}${title:+ (${title})} is registered in Grafana"
    else
      fail_item "${name} is on disk and not in Grafana: ${uid}${title:+ (${title})} is missing from ${OBS_DASHBOARD_SEARCH}, so the file provider never imported it - check that the JSON parses and that ${OBS_DASHBOARD_DIR} is the directory bound to /var/lib/grafana/dashboards"
    fi
  done
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
check_exporters
check_rules
check_dashboards
finish
