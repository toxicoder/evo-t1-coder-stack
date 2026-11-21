#!/usr/bin/env bats
#
# ## observability-check.bats - hermetic coverage for scripts/observability-check.sh.
#
# The contract pinned here is the one the operator reads, not the one the code
# finds easiest: the usage line and the two-character exit that answers a typo;
# the Mimir day-suffix that is a startup failure and not a preference; the empty
# log tree that is the stack's known silent failure (Alloy tails nothing, calls it
# healthy, and Loki stays empty forever); the switched-off bundle that must not
# fail a run for containers it was told not to start; the container that is not
# running, named by its service; and the `summary: N ok, W warnings, F failed`
# line that closes every run, always last, because that line is what a caller
# greps.
#
# Hermetic by construction. setup() shadows `docker` and `curl` with one private
# bin/ directory prepended to PATH: the CLI shells out to those two and to nothing
# else that could reach a daemon or a socket, while the coreutils it pipes through
# (grep, awk, sed, find, wc, tr, basename, dirname) stay the host's. A suite that
# hid those too would test a PATH no operator has ever run on. The stubs are
# written into this test's tmpdir and replay argv-driven plans, so no test pulls
# an image, opens a socket, or depends on a bundle being up.
#
# The whole suite skips while scripts/observability-check.sh is absent: a suite for
# a script that does not exist yet has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_observability_check_test   (from any cwd)
# Safety: stubs and canned bodies only. No live service, no Docker, no network,
# and no file outside this test's tmpdir.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
LIB=""
SCRATCH=""
PROJ=""
PROMETHEUS_YML=""
DASHBOARD_DIR=""

# The profile-gated services the CLI walks, as scripts/observability-check.sh
# declares them: the six pipeline containers plus the four exporters the same
# profile publishes on loopback. The canned render, the canned ps table and the
# canned container states all come from this one list.
OBS_LIST=(prometheus loki mimir tempo grafana alloy node_exporter cadvisor
  blackbox_exporter alertmanager)

# setup - resolve the checkout, write the two stubs, and lay out one healthy
# shape (ten services rendered, ten containers running, four in-network probes
# answering 200, every target up, nothing failed to Mimir, the four host exporters
# exposing their families, both blackbox modules probing green, every rule file
# prometheus.yml names loaded with a rule in it, and every dashboard in the repo
# answered by Grafana's search API) that individual tests narrow. Nothing from
# this process's environment is allowed to decide what the run reads, so every key
# the CLI consults is cleared first.
# Globals:
#   REPO_ROOT, SCRIPT, LIB, SCRATCH, PROJ, PROMETHEUS_YML, DASHBOARD_DIR,
#   OBS_LIST, PATH
# Arguments:
#   None
# Outputs:
#   The private bin/, the fixture compose project, and the stub plan files
# Returns:
#   0, or a skip when the script or its lib is not in the tree
setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/observability-check.sh"
  LIB="${REPO_ROOT}/scripts/lib/common.sh"
  if [ ! -f "${SCRIPT}" ] || [ ! -f "${LIB}" ]; then
    skip "scripts/observability-check.sh or its lib is not in the tree"
  fi

  SCRATCH="$(make_scratch)"
  PROJ="${SCRATCH}/proj"
  mkdir -p "${SCRATCH}/bin" "${PROJ}" "${SCRATCH}/stub-logs"
  export STUB_LOG="${SCRATCH}/stub-logs"
  write_docker_stub "${SCRATCH}/bin"
  write_curl_stub "${SCRATCH}/bin"
  PATH="$(with_path "${SCRATCH}/bin")"
  export PATH

  unset OBSERVABILITY_ENABLED ENV_FILE COMPOSE_FILE JSON_MODE
  unset GRAFANA_PORT GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
  unset PROMETHEUS_PORT PROMETHEUS_URL STACK_DOCKER_LOG_DIR MIMIR_RETENTION_PERIOD
  unset DOCKER_SERVICES_FILE DOCKER_PS_FILE DOCKER_STATE_FILE DOCKER_RUN_FILE
  unset DOCKER_CONFIG_FAIL DOCKER_PS_FAIL CURL_PLAN EXPORTER_PLAN RULES_PLAN SEARCH_PLAN

  PROMETHEUS_YML="${REPO_ROOT}/observability/prometheus/prometheus.yml"
  DASHBOARD_DIR="${REPO_ROOT}/observability/grafana/dashboards"
  # The Spark flag the data flow section now consults. Unset is the shipped
  # default (.env.example:629), and no ambient value may decide that here.
  unset SPARK_MONITOR_ENABLED

  printf '%s\n' 'services: {}' >"${PROJ}/docker-compose.yml"
  export COMPOSE_FILE="${PROJ}/docker-compose.yml"

  : >"${SCRATCH}/services"
  : >"${SCRATCH}/ps"
  : >"${SCRATCH}/state"
  local service
  for service in "${OBS_LIST[@]}"; do
    printf '%s\n' "${service}" >>"${SCRATCH}/services"
    printf '%s obs-%s-1\n' "${service}" "${service}" >>"${SCRATCH}/ps"
    printf 'obs-%s-1=running\n' "${service}" >>"${SCRATCH}/state"
  done
  printf '%s\n' \
    'http://loki:3100/ready=200' \
    'http://mimir:8080/ready=200' \
    'http://tempo:3200/ready=200' \
    'http://alloy:12345/-/ready=200' >"${SCRATCH}/codes"
  export DOCKER_SERVICES_FILE="${SCRATCH}/services"
  export DOCKER_PS_FILE="${SCRATCH}/ps"
  export DOCKER_STATE_FILE="${SCRATCH}/state"
  export DOCKER_RUN_FILE="${SCRATCH}/codes"

  write_targets_body "${SCRATCH}/targets-up.json" up up
  write_scraped_targets_body "${SCRATCH}/targets-scraped.json"
  write_exporter_bodies "${SCRATCH}"
  stub_exporters
  write_rules_body "${SCRATCH}/rules-loaded.json"
  write_search_body "${SCRATCH}/search-all.json"
  stub_rules "${SCRATCH}/rules-loaded.json"
  stub_grafana_search "${SCRATCH}/search-all.json"
  printf '%s\n' \
    '# TYPE prometheus_remote_storage_samples_failed_total counter' \
    'prometheus_remote_storage_samples_failed_total{queue="0"} 0' >"${SCRATCH}/metrics-clean.txt"
  stub_prometheus "${SCRATCH}/targets-scraped.json" "${SCRATCH}/metrics-clean.txt"

  seed_log_dir "${SCRATCH}/logs-full" a1b2c3d4e5
}

# write_docker_stub <dir> - the docker stand-in: replays the canned compose render,
# the canned ps table, one State.Status per container name, and one HTTP code per
# in-network URL. Nothing here talks to a daemon; an argv line is the only input.
# Globals:
#   STUB_LOG
# Arguments:
#   $1 - directory to write the stub into
# Outputs:
#   <dir>/docker, mode 755, and its argv log under STUB_LOG
# Returns:
#   0
write_docker_stub() {
  cat >"${1}/docker" <<'STUB'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_LOG:-}" ]; then printf 'docker %s\n' "$*" >>"${STUB_LOG}/docker.log"; fi
argv="$*"
case "${argv}" in
  *'config --services'*)
    if [ -n "${DOCKER_CONFIG_FAIL:-}" ]; then
      printf 'error: yaml: file %s not found\n' "${argv}" >&2
      exit 1
    fi
    cat "${DOCKER_SERVICES_FILE:?}"
    ;;
  *'ps --format'*)
    if [ -n "${DOCKER_PS_FAIL:-}" ]; then
      printf 'error: Cannot connect to the Docker daemon\n' >&2
      exit 1
    fi
    cat "${DOCKER_PS_FILE:?}"
    ;;
  inspect*)
    name="${*: -1}"
    line="$(grep "^${name}=" "${DOCKER_STATE_FILE:-/dev/null}" 2>/dev/null | tail -n 1 || true)"
    if [ -z "${line}" ]; then
      printf 'Error: No such object: %s\n' "${name}" >&2
      exit 1
    fi
    printf '%s\n' "${line#*=}"
    ;;
  run*)
    url="${*: -1}"
    code="$(sed -n "s|^${url}=||p" "${DOCKER_RUN_FILE:-/dev/null}" | tail -n 1)"
    printf '%s' "${code:-200}"
    ;;
  *)
    printf 'docker stub: unmatched argv: %s\n' "${argv}" >&2
    exit 9
    ;;
esac
STUB
  chmod 755 "${1}/docker"
}

# write_curl_stub <dir> - the curl stand-in: the last argv word is the URL, and a
# plan of `url|exit-code|body-file|http-code` entries says how that URL answers. A
# URL the plan does not name answers 200 with an empty body, and a non-zero exit
# code stands in for what curl's own -f does to a non-2xx. The http-code field is
# optional and answers a probe that asked for -w instead of -f, which is how
# scripts/observability-check.sh tells a refused socket from a 404 from a 200 with
# the wrong body.
# Globals:
#   STUB_LOG
# Arguments:
#   $1 - directory to write the stub into
# Outputs:
#   <dir>/curl, mode 755, and its argv log under STUB_LOG
# Returns:
#   0
write_curl_stub() {
  cat >"${1}/curl" <<'STUB'
#!/usr/bin/env bash
set -u
if [ -n "${STUB_LOG:-}" ]; then printf 'curl %s\n' "$*" >>"${STUB_LOG}/curl.log"; fi
url="${*: -1}"
rc=0
code=200
body=""
out=""
want_code=""
prev=""
for arg in "$@"; do
  if [ "${prev}" = "-o" ]; then out="${arg}"; fi
  if [ "${prev}" = "-w" ]; then want_code="${arg}"; fi
  prev="${arg}"
done
if [ -n "${CURL_PLAN:-}" ]; then
  IFS=';' read -ra plan_entries <<<"${CURL_PLAN}"
  for entry in "${plan_entries[@]}"; do
    case "${entry}" in
      *'|'*'|'*) ;;
      *) continue ;;
    esac
    e_url="${entry%%|*}"
    rest="${entry#*|}"
    e_rc="${rest%%|*}"
    rest="${rest#*|}"
    if [[ "${rest}" == *'|'* ]]; then
      e_body="${rest%%|*}"
      e_code="${rest#*|}"
    else
      e_body="${rest}"
      e_code=""
    fi
    if [ "${e_url}" = "${url}" ]; then
      rc="${e_rc}"
      body="${e_body}"
      code="${e_code:-200}"
    fi
  done
fi
if [ "${rc}" != "0" ]; then
  printf 'curl: (%s) The requested URL returned an error\n' "${rc}" >&2
  case "${rc}" in '' | *[!0-9]* | 0) rc=1 ;; esac
  exit "${rc}"
fi
if [ -n "${out}" ]; then
  if [ -n "${body}" ] && [ -f "${body}" ]; then cat "${body}" >"${out}"; else : >"${out}"; fi
elif [ -n "${body}" ] && [ -f "${body}" ]; then
  cat "${body}"
fi
if [ -n "${want_code}" ]; then printf '%s' "${code}"; fi
exit 0
STUB
  chmod 755 "${1}/curl"
}

# seed_log_dir <dir> <id> - one container's worth of the tree Alloy tails:
# <dir>/<id>/<id>-json.log, the only layout the daemon writes.
# Globals:
#   None
# Arguments:
#   $1 - the log directory; $2 - the container id
# Outputs:
#   The seeded tree
# Returns:
#   0
seed_log_dir() {
  mkdir -p "${1}/${2}"
  printf '{"log":"hello\\n","stream":"stdout","time":"2026-01-01T00:00:00Z"}\n' >"${1}/${2}/${2}-json.log"
}

# write_env_file <path> [KEY=value...] - the fixture dotenv, with each override
# replacing its key so a test states only the one key it is about.
# Globals:
#   SCRATCH
# Arguments:
#   $1 - file to write; the rest are KEY=value overrides
# Outputs:
#   The env file
# Returns:
#   0
write_env_file() {
  local path="$1"
  shift
  cat >"${path}" <<ENV
OBSERVABILITY_ENABLED=true
GRAFANA_PORT=3005
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=hunter2-not-printed
PROMETHEUS_PORT=9090
PROMETHEUS_URL=
PROMETHEUS_RETENTION_TIME=15d
PROMETHEUS_RETENTION_SIZE=10GB
LOKI_RETENTION_PERIOD=168h
TEMPO_BLOCK_RETENTION_TIME=168h
MIMIR_RETENTION_PERIOD=2160h
STACK_DOCKER_LOG_DIR=${SCRATCH}/logs-full
ENV
  local override key
  for override in "$@"; do
    key="${override%%=*}"
    grep -v "^${key}=" "${path}" >"${path}.tmp" || true
    mv "${path}.tmp" "${path}"
    printf '%s\n' "${override}" >>"${path}"
  done
}

# drop_env_key <path> <KEY> - delete a key outright, which is the state where
# compose's own default is the only answer, and the one env_get cannot tell apart
# from the key being present and empty.
# Globals:
#   None
# Arguments:
#   $1 - the file to edit; $2 - the key to remove
# Outputs:
#   The edited file
# Returns:
#   0
drop_env_key() {
  grep -v "^${2}=" "${1}" >"${1}.tmp" || true
  mv "${1}.tmp" "${1}"
}

# write_targets_body <path> <health-a> <health-b> [<error-a> <error-b>] - a
# Prometheus /api/v1/targets body with two active targets, one per health value,
# in the field order Prometheus itself emits (labels before health, lastError
# immediately before it). The two error arguments plant each target's lastError;
# left out they stay the empty string Prometheus writes for a target that never
# failed, which is what every caller that only cares about health passes.
# Globals:
#   None
# Arguments:
#   $1 - file to write; $2 - health of the prometheus job; $3 - health of the
#   litellm job; $4 - lastError of the prometheus job; $5 - lastError of the
#   litellm job
# Outputs:
#   The body file
# Returns:
#   0
write_targets_body() {
  local path="$1" health_a="$2" health_b="$3" error_a="${4:-}" error_b="${5:-}"
  printf '%s\n' "{\"status\":\"success\",\"data\":{\"activeTargets\":[\
{\"discoveredLabels\":{\"__address__\":\"127.0.0.1:9090\"},\"labels\":{\"instance\":\"127.0.0.1:9090\",\"job\":\"prometheus\"},\"scrapeUrl\":\"http://127.0.0.1:9090/metrics\",\"lastError\":\"${error_a}\",\"health\":\"${health_a}\"},\
{\"discoveredLabels\":{\"__address__\":\"litellm:4000\"},\"labels\":{\"instance\":\"litellm:4000\",\"job\":\"litellm\"},\"scrapeUrl\":\"http://litellm:4000/metrics\",\"lastError\":\"${error_b}\",\"health\":\"${health_b}\"}\
],\"droppedTargets\":[]}}" >"${path}"
}

# stub_prometheus <targets-file> <metrics-file> - point the curl plan at the two
# bodies the data flow section reads; the loopback health endpoints keep answering
# 200 with an empty body, and the exporter plan from stub_exporters rides along so
# a test that narrows one URL does not fail on the other seven. The rules and
# dashboard-search answers from stub_rules and stub_grafana_search ride with them,
# because a test that rebuilds this plan to break one API must not be left with
# fifteen errors from the two sections whose bodies it never mentioned.
# Globals:
#   SCRATCH, EXPORTER_PLAN, RULES_PLAN, SEARCH_PLAN
# Arguments:
#   $1 - targets body; $2 - metrics body
# Outputs:
#   CURL_PLAN
# Returns:
#   0
stub_prometheus() {
  export CURL_PLAN="${EXPORTER_PLAN};${RULES_PLAN};${SEARCH_PLAN};http://127.0.0.1:9090/-/healthy|0|;http://127.0.0.1:3005/api/health|0|;\
http://127.0.0.1:9090/api/v1/targets|0|${1};http://127.0.0.1:9090/metrics|0|${2};${RULES_PLAN};${SEARCH_PLAN}"
}

# stub_rules <body-file> - answer Prometheus's rules API from one body. The curl
# stub's last match wins, so a test that wants a different answer for that one URL
# appends its own entry rather than rebuilding the plan.
# Globals:
#   CURL_PLAN
# Arguments:
#   $1 - the body to serve
# Outputs:
#   RULES_PLAN, and CURL_PLAN with that entry appended
# Returns:
#   0
stub_rules() {
  export RULES_PLAN="http://127.0.0.1:9090/api/v1/rules|0|${1}|200"
  export CURL_PLAN="${CURL_PLAN};${RULES_PLAN}"
}

# stub_grafana_search <body-file> - answer the dashboard search API the same way.
# Globals:
#   CURL_PLAN
# Arguments:
#   $1 - the body to serve
# Outputs:
#   SEARCH_PLAN, and CURL_PLAN with that entry appended
# Returns:
#   0
stub_grafana_search() {
  export SEARCH_PLAN="http://127.0.0.1:3005/api/search?type=dash-db|0|${1}|200"
  export CURL_PLAN="${CURL_PLAN};${SEARCH_PLAN}"
}

# write_spark_root <dir> - a second root for the Spark file-SD check: the marker
# resolve_repo_root probes, plus the two paths the rules and dashboards sections
# read, copied out of the real tree so those sections answer exactly as they do in
# the healthy shape. The file it exists for, observability/spark-targets/sparks.json,
# is generated by //scripts:spark-monitor -- --apply and is gitignored, so only a
# fixture can decide whether it is there.
# Globals:
#   PROMETHEUS_YML, DASHBOARD_DIR
# Arguments:
#   $1 - directory to build
# Outputs:
#   <dir>/docker-compose.yml and <dir>/observability/{prometheus,grafana}
# Returns:
#   0
write_spark_root() {
  mkdir -p "${1}/observability/prometheus" "${1}/observability/grafana"
  printf '%s\n' 'services: {}' >"${1}/docker-compose.yml"
  cp "${PROMETHEUS_YML}" "${1}/observability/prometheus/prometheus.yml"
  cp -R "${DASHBOARD_DIR}" "${1}/observability/grafana/dashboards"
}

# write_rules_body <path> [mode] - a Prometheus /api/v1/rules body carrying one
# group with one healthy rule for every file the repo's own prometheus.yml lists
# under rule_files:. The mode withholds something from one file: `missing:<file>`
# drops that group outright, `empty:<file>` loads the group with no rule in it.
# Read out of the config rather than hardcoded, so the healthy shape stays healthy
# whatever the bundle's rule set grows by.
# Globals:
#   PROMETHEUS_YML
# Arguments:
#   $1 - file to write; $2 - optional mode
# Outputs:
#   The body file
# Returns:
#   0
write_rules_body() {
  local path="$1" mode="${2:-}" file name row first=1
  {
    printf '%s' '{"status":"success","data":{"groups":['
    while IFS= read -r file; do
      [ -n "${file}" ] || continue
      case "${mode}" in "missing:${file}") continue ;; esac
      name="${file##*/}"
      name="${name%.yml}"
      if [ "${mode}" = "empty:${file}" ]; then
        row="$(printf '{"name":"%s","file":"%s","interval":60,"rules":[]}' "${name}" "${file}")"
      else
        row="$(printf '{"name":"%s","file":"%s","interval":60,"rules":[{"name":"%sMissing","query":"up == 0","health":"ok","state":"inactive","labels":{},"annotations":{}}]}' \
          "${name}" "${file}" "${name}")"
      fi
      if [ "${first}" = "1" ]; then
        first=0
      else
        printf '%s' ','
      fi
      printf '%s' "${row}"
    done < <(sed -n '/^rule_files:/,/^[^ ]/p' "${PROMETHEUS_YML}" 2>/dev/null |
      sed -n 's/^[[:space:]]*-[[:space:]]*\(.*\)/\1/p')
    printf '%s\n' ']}}'
  } >"${path}"
}

# write_search_body <path> [omit-uid] - a Grafana /api/search?type=dash-db body
# carrying every dashboard the repo ships, with each uid and title read out of the
# file itself. The second argument leaves one uid out of the answer, which is the
# state where the file provider never imported that dashboard.
# Globals:
#   DASHBOARD_DIR
# Arguments:
#   $1 - file to write; $2 - uid to leave out, if any
# Outputs:
#   The body file
# Returns:
#   0
write_search_body() {
  local path="$1" omit="${2:-}" file uid title row first=1
  {
    printf '%s' '['
    for file in "${DASHBOARD_DIR}"/*.json; do
      [ -f "${file}" ] || continue
      uid="$(sed -n 's/^  "uid": "\([^"]*\)".*/\1/p' "${file}" | head -n 1)"
      [ -n "${uid}" ] || continue
      [ "${uid}" != "${omit}" ] || continue
      title="$(sed -n 's/^  "title": "\([^"]*\)".*/\1/p' "${file}" | head -n 1)"
      row="$(printf '{"type":"dash-db","title":"%s","uid":"%s"}' "${title}" "${uid}")"
      if [ "${first}" = "1" ]; then
        first=0
      else
        printf '%s' ','
      fi
      printf '%s' "${row}"
    done
    printf '%s\n' ']'
  } >"${path}"
}

# write_exporter_bodies <dir> - one canned /metrics body per host exporter, each
# holding the family scripts/observability-check.sh expects to see, plus the
# /probe bodies the prober round-trip parses. Text only: no exporter, no socket.
# Globals:
#   None
# Arguments:
#   $1 - directory to write into
# Outputs:
#   <dir>/<exporter>.metrics.txt and the canned /probe bodies
# Returns:
#   0
write_exporter_bodies() {
  local dir="$1"
  printf '%s\n' \
    '# TYPE node_filefd_allocated gauge' \
    'node_filefd_allocated 1234' >"${dir}/node_exporter.metrics.txt"
  printf '%s\n' \
    '# TYPE container_last_seen gauge' \
    'container_last_seen{id="/"} 1767225600' >"${dir}/cadvisor.metrics.txt"
  printf '%s\n' \
    '# TYPE blackbox_exporter_config_last_reload_success_timestamp_seconds gauge' \
    'blackbox_exporter_config_last_reload_success_timestamp_seconds 1767225600' \
    >"${dir}/blackbox_exporter.metrics.txt"
  printf '%s\n' \
    '# TYPE alertmanager_alerts gauge' \
    'alertmanager_alerts{state="active"} 0' >"${dir}/alertmanager.metrics.txt"
  printf '%s\n' '# TYPE go_goroutines gauge' 'go_goroutines 11' >"${dir}/metrics-no-family.txt"
  printf '%s\n' 'probe_success 1' 'probe_http_status_code 200' >"${dir}/probe-green.txt"
  printf '%s\n' 'probe_success 0' 'probe_http_status_code 0' >"${dir}/probe-red.txt"
  printf '%s\n' 'probe_duration_seconds 0.004' >"${dir}/probe-no-series.txt"
  printf '%s\n' 'Target module spark_health not found' >"${dir}/probe-no-module.txt"
}

# stub_exporters - the green answer for every exporter URL the exporters section
# asks: four /metrics bodies carrying their family, Alertmanager's /-/ready, and
# both blackbox module round-trips answering probe_success 1.
# Globals:
#   SCRATCH
# Arguments:
#   None
# Outputs:
#   EXPORTER_PLAN
# Returns:
#   0
stub_exporters() {
  local bb_target='http://prometheus:9090/-/healthy'
  EXPORTER_PLAN="http://127.0.0.1:9101/metrics|0|${SCRATCH}/node_exporter.metrics.txt|200;\
http://127.0.0.1:9290/metrics|0|${SCRATCH}/cadvisor.metrics.txt|200;\
http://127.0.0.1:9115/metrics|0|${SCRATCH}/blackbox_exporter.metrics.txt|200;\
http://127.0.0.1:9093/metrics|0|${SCRATCH}/alertmanager.metrics.txt|200;\
http://127.0.0.1:9093/-/ready|0|;\
http://127.0.0.1:9115/probe?module=spark_health&target=${bb_target}|0|${SCRATCH}/probe-green.txt|200;\
http://127.0.0.1:9115/probe?module=spark_models&target=${bb_target}|0|${SCRATCH}/probe-green.txt|200"
  export EXPORTER_PLAN
}

# write_scraped_targets_body <path> - the healthy target list: the two jobs
# write_targets_body emits plus the five the exporters section expects Prometheus
# to collect (observability/prometheus/prometheus.yml:124,133,164,184,200), all up.
# Globals:
#   None
# Arguments:
#   $1 - file to write
# Outputs:
#   The body file
# Returns:
#   0
write_scraped_targets_body() {
  local path="$1" job rows="" sep=""
  for job in prometheus litellm node_exporter cadvisor blackbox-spark \
    blackbox-spark-models alertmanager; do
    rows="${rows}${sep}{\"discoveredLabels\":{\"__address__\":\"${job}:9101\"},\
\"labels\":{\"instance\":\"${job}:9101\",\"job\":\"${job}\"},\
\"scrapeUrl\":\"http://${job}:9101/metrics\",\"lastError\":\"\",\"health\":\"up\"}"
    sep=","
  done
  printf '%s\n' \
    "{\"status\":\"success\",\"data\":{\"activeTargets\":[${rows}],\"droppedTargets\":[]}}" >"${path}"
}

# assert_summary_is_last_line - the grammar's one absolute rule: whatever else the
# run printed, the line a caller greps is the line that closes it.
# Globals:
#   output
# Arguments:
#   None
# Outputs:
#   One FAIL line on mismatch
# Returns:
#   0 when the last line of $output is the summary
assert_summary_is_last_line() {
  local last
  last="$(printf '%s\n' "${output}" | tail -n 1)"
  assert_match "the summary closes the run" \
    '^summary: [0-9]+ ok, [0-9]+ warnings, [0-9]+ failed$' "${last}"
}

@test "--help prints the usage block and exits 0" {
  run bash "${SCRIPT}" --help
  assert_eq "help exits 0" 0 "${status}"
  assert_match "the usage line names the target" \
    'Usage: bazelisk run //scripts:observability-check -- \[OPTIONS\]' "${output}"
  assert_match "the flags are all listed" '--env-file PATH' "${output}"
  assert_match "the docker switch is listed" '--no-docker' "${output}"
  assert_match "the timeout knob is listed" '--timeout SECS' "${output}"
}

@test "an unknown option goes to stderr with the usage line and exits 2" {
  run --separate-stderr bash "${SCRIPT}" --not-a-flag
  assert_eq "the usage error exits 2" 2 "${status}"
  assert_match "the complaint names the option" '^error: unknown option: --not-a-flag$' "${stderr}"
  assert_match "the usage line rides with it" \
    'Usage: bazelisk run //scripts:observability-check' "${stderr}"
  assert_eq "nothing is printed on stdout" "" "${output}"
}

@test "a bad --timeout value is a usage error answered before any probe" {
  run bash "${SCRIPT}" --timeout soon
  assert_eq "the usage error exits 2" 2 "${status}"
  assert_match "the complaint says what --timeout wants" \
    'error: unknown option: --timeout needs a whole number of seconds' "${output}"
  assert_not_match "no section was printed" '== configuration ==' "${output}"
}

@test "MIMIR_RETENTION_PERIOD in days is an error that names the key" {
  write_env_file "${SCRATCH}/mimir-days.env" 'MIMIR_RETENTION_PERIOD=90d'
  run bash "${SCRIPT}" --env-file "${SCRATCH}/mimir-days.env" --no-docker
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a day suffix must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the error names the key and its value" \
    '^error: MIMIR_RETENTION_PERIOD=90d' "${output}"
  assert_match "the error says hours only" 'hours only' "${output}"

  # The same fixture with the hours spelling is clean, so the error above is the
  # key and not the rest of the run talking.
  write_env_file "${SCRATCH}/mimir-hours.env" 'MIMIR_RETENTION_PERIOD=2160h'
  run bash "${SCRIPT}" --env-file "${SCRATCH}/mimir-hours.env" --no-docker
  assert_not_match "hours is not a failure" 'hours only' "${output}"
  assert_match "hours is reported as read" 'ok: MIMIR_RETENTION_PERIOD=2160h' "${output}"
}

@test "an empty log tree is the silent failure, and a seeded one is not" {
  mkdir -p "${SCRATCH}/logs-empty"
  write_env_file "${SCRATCH}/empty-logs.env" "STACK_DOCKER_LOG_DIR=${SCRATCH}/logs-empty"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/empty-logs.env" --no-docker
  assert_match "the finding says Alloy would ship nothing" \
    'error: .*Alloy would ship nothing' "${output}"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: an empty log tree must fail the run, got %s\n' "${status}" >&2
    return 1
  }

  seed_log_dir "${SCRATCH}/logs-two" c0ffee99
  write_env_file "${SCRATCH}/seeded.env" "STACK_DOCKER_LOG_DIR=${SCRATCH}/logs-two"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/seeded.env" --no-docker
  assert_not_match "a seeded tree is not the silent failure" \
    'Alloy would ship nothing' "${output}"
  assert_match "the seeded tree is counted" \
    'ok: .*logs-two holds 1 container log file' "${output}"
}

@test "an absent key notes, a blank required key warns, a blank password names bootstrap" {
  write_env_file "${SCRATCH}/blanks.env" 'GRAFANA_ADMIN_PASSWORD=' 'GRAFANA_ADMIN_USER='
  drop_env_key "${SCRATCH}/blanks.env" PROMETHEUS_RETENTION_SIZE
  run bash "${SCRIPT}" --env-file "${SCRATCH}/blanks.env" --no-docker
  assert_eq "a blank value is a warning and not a failure" 0 "${status}"
  assert_match "a blank password names bootstrap" \
    'warning: GRAFANA_ADMIN_PASSWORD is blank: .*//scripts:bootstrap' "${output}"
  assert_match "any other blank required key warns" \
    'warning: GRAFANA_ADMIN_USER is present but blank' "${output}"
  assert_match "an absent key is only a note" \
    'note: PROMETHEUS_RETENTION_SIZE is unset: compose ships a default for it' "${output}"
  assert_not_match "an absent key is never a warning" \
    'warning: PROMETHEUS_RETENTION_SIZE' "${output}"
  assert_summary_is_last_line
}

@test "--timeout is the budget every curl is given" {
  write_env_file "${SCRATCH}/timeout.env"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/timeout.env" --timeout 2 --no-docker
  assert_eq "the run still finishes" 0 "${status}"
  assert_match "curl carried --max-time 2" '--max-time 2' "$(stub_log curl)"
  assert_match "curl still ran with -fsS" '-fsS' "$(stub_log curl)"
}

@test "OBSERVABILITY_ENABLED=false switches the bundle off and exits 0" {
  write_env_file "${SCRATCH}/off.env" 'OBSERVABILITY_ENABLED=false'
  run bash "${SCRIPT}" --env-file "${SCRATCH}/off.env"
  assert_eq "the off path exits 0" 0 "${status}"
  assert_match "the switch-off is announced with its value" \
    '^note: the bundle is switched off \(OBSERVABILITY_ENABLED=false\)$' "${output}"
  assert_match "the configuration still ran" '== configuration ==' "${output}"
  assert_match "the log source still ran" '== log source ==' "${output}"
  assert_match "the render section skipped itself" \
    'note: skipped: the bundle is switched off, so there is no profile to render' "${output}"
  assert_match "the endpoints section skipped itself" \
    'note: skipped: the bundle is switched off, so no endpoint is expected to answer' "${output}"
  assert_match "the run still closes with a summary" \
    '^summary: [0-9]+ ok, [0-9]+ warnings, 0 failed$' "${output}"
  assert_summary_is_last_line
  # Nothing shelled out to docker, so the stubs must have logged nothing.
  assert_eq "no docker call was made" "0" "$(stub_log_count docker)"
  assert_eq "no curl call was made" "0" "$(stub_log_count curl)"
}

@test "a healthy bundle reports 0 failed and exits 0" {
  write_env_file "${SCRATCH}/good.env"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/good.env"
  assert_eq "a healthy run exits 0" 0 "${status}"
  assert_match "nothing failed" '^summary: [0-9]+ ok, [0-9]+ warnings, 0 failed$' "${output}"
  assert_summary_is_last_line
  local service
  for service in "${OBS_LIST[@]}"; do
    assert_match "the render lists ${service}" \
      "ok: compose renders ${service} under the observability profile" "${output}"
    assert_match "the container for ${service} runs" \
      "ok: ${service} container obs-${service}-1 is running" "${output}"
  done
  assert_match "prometheus is healthy on loopback" \
    'ok: prometheus answers at http://127.0.0.1:9090/-/healthy' "${output}"
  assert_match "grafana is healthy on loopback" \
    'ok: grafana answers at http://127.0.0.1:3005/api/health' "${output}"
  assert_match "the portless services are probed in-network" \
    'ok: alloy is ready: 200 from http://alloy:12345/-/ready' "${output}"
  assert_match "all targets are up" 'ok: prometheus scrape targets: all 7 up' "${output}"
  assert_match "remote_write is clean" \
    'ok: prometheus remote_write: no failed samples to Mimir' "${output}"
  assert_match "node_exporter answers with its family" \
    'ok: node_exporter answers at http://127.0.0.1:9101/metrics and exposes node_filefd_allocated series' "${output}"
  assert_match "cAdvisor answers with its family" \
    'ok: cadvisor answers at http://127.0.0.1:9290/metrics and exposes container_last_seen series' "${output}"
  assert_match "blackbox answers with its own series" \
    'ok: blackbox_exporter answers at http://127.0.0.1:9115/metrics and exposes blackbox_exporter_ series' "${output}"
  assert_match "Alertmanager answers on both its verbs" \
    'ok: alertmanager answers at http://127.0.0.1:9093/-/ready' "${output}"
  assert_match "the prober ran both pinned modules" \
    'ok: blackbox_exporter ran the spark_models probe of http://prometheus:9090/-/healthy: probe_success 1' "${output}"
  assert_match "Prometheus still collects the exporters" \
    'ok: prometheus collects the blackbox-spark-models job' "${output}"
  assert_not_match "the admin password is never printed" 'hunter2' "${output}"
  assert_match "the password key is still reported" \
    'ok: GRAFANA_ADMIN_PASSWORD is set \(value not printed\)' "${output}"
  assert_match "the probes joined the project network" \
    "--network proj_default curlimages/curl:8.10.1" "$(stub_log docker)"
}

@test "one container that is not running names its service and fails the run" {
  write_env_file "${SCRATCH}/exited.env"
  printf '%s\n' 'obs-grafana-1=exited' >>"${SCRATCH}/state"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/exited.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: an exited container must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the failing service is named" \
    "error: grafana container obs-grafana-1 reports 'exited', not running" "${output}"
  assert_match "the fix is named" '//scripts:dev-stack -- up' "${output}"
  assert_match "the other nine are still reported" \
    'ok: prometheus container obs-prometheus-1 is running' "${output}"
  assert_match "the summary counts the failure" \
    '^summary: [0-9]+ ok, [0-9]+ warnings, 1 failed$' "${output}"
  assert_summary_is_last_line
}

@test "a service with no container says the bundle was never started" {
  write_env_file "${SCRATCH}/absent.env"
  printf '%s\n' 'alloy obs-alloy-1' >"${SCRATCH}/ps"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/absent.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a missing container must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the service is named" 'error: prometheus has no container' "${output}"
  assert_match "the suggestion is dev-stack up" '//scripts:dev-stack -- up' "${output}"
}

@test "a compose render that cannot run is one error and the section is skipped" {
  write_env_file "${SCRATCH}/render.env"
  export DOCKER_CONFIG_FAIL=1
  run bash "${SCRIPT}" --env-file "${SCRATCH}/render.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: an unrenderable compose file must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "one error names the compose file" \
    '^error: docker compose could not render ' "${output}"
  assert_not_match "the ten services are not each blamed on top of it" \
    'is not in the observability profile' "${output}"
  assert_summary_is_last_line
}

@test "--no-docker skips every daemon check and keeps the rest" {
  write_env_file "${SCRATCH}/nodocker.env"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/nodocker.env" --no-docker
  assert_eq "a machine with no daemon still answers 0 when what it can see is fine" 0 "${status}"
  local service
  for service in loki mimir tempo alloy; do
    assert_match "${service} is noted as skipped" \
      "note: ${service} .* skipped \\(--no-docker\\)" "${output}"
  done
  assert_match "the render section said it needs the CLI" \
    'note: skipped \(--no-docker\): the render needs the docker CLI' "${output}"
  assert_match "the container section said the same" \
    'note: skipped \(--no-docker\): container state comes from the daemon' "${output}"
  assert_match "the loopback probes still ran" \
    'ok: grafana answers at http://127.0.0.1:3005/api/health' "${output}"
  assert_match "the log source still ran without a daemon" \
    'ok: .*logs-full holds 1 container log file' "${output}"
  assert_match "the exporter probes still ran over loopback" \
    'ok: alertmanager answers at http://127.0.0.1:9093/-/ready' "${output}"
  assert_eq "docker was never called" "0" "$(stub_log_count docker)"
  assert_summary_is_last_line
}

@test "a down target is a warning that names its job and its empty lastError" {
  write_env_file "${SCRATCH}/down.env"
  write_targets_body "${SCRATCH}/targets-down.json" up down
  stub_prometheus "${SCRATCH}/targets-down.json" "${SCRATCH}/metrics-clean.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/down.env"
  assert_eq "a red target is a warning, not a failure" 0 "${status}"
  assert_match "the down job is named" \
    "warning: prometheus target job 'litellm' reports 'down', not up" "${output}"
  assert_match "a target that recorded nothing prints the placeholder, not a blank" \
    "reports 'down', not up: lastError '-'" "${output}"
  assert_not_match "the up job is not named" "job 'prometheus' reports" "${output}"
  assert_match "the tally is printed" 'ok: prometheus scrape targets: 1 of 2 up' "${output}"
  assert_summary_is_last_line
}

@test "a red litellm target with a 401 names the token file and the config that fills it" {
  write_env_file "${SCRATCH}/litellm-down.env"
  write_targets_body "${SCRATCH}/targets-litellm-down.json" up down "" \
    "server returned HTTP status 401 Unauthorized"
  stub_prometheus "${SCRATCH}/targets-litellm-down.json" "${SCRATCH}/metrics-clean.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/litellm-down.env"
  assert_eq "a red target with a cause still exits 0" 0 "${status}"
  assert_match "the down job is still named on its own line" \
    "warning: prometheus target job 'litellm' reports 'down', not up" "${output}"
  assert_match "the warning carries the target's own lastError" \
    "lastError 'server returned HTTP status 401 Unauthorized'" "${output}"
  assert_match "the finding names the token file and where it lives" \
    'warning: that lastError is the bearer, not the proxy: /etc/prometheus-secrets/litellm_token in the prometheus container has to hold the key' "${output}"
  assert_match "the finding tells the operator to compare without printing the key" \
    'compare the two by hash, never by printing them' "${output}"
  assert_match "the finding names the recreate a rotated key needs" \
    'up -d --force-recreate prometheus' "${output}"
  assert_match "a red target is still no failure" \
    '^summary: [0-9]+ ok, [0-9]+ warnings, 0 failed$' "${output}"
  assert_not_match "metrics auth is never offered as the fix" \
    'require_auth_for_metrics_endpoint' "${output}"
  assert_summary_is_last_line
}

@test "an unreadable bearer file is quoted and still points at the token file" {
  write_env_file "${SCRATCH}/litellm-nofile.env"
  write_targets_body "${SCRATCH}/targets-litellm-nofile.json" up down "" \
    'Get \"http://litellm:4000/metrics\": unable to read authorization credentials: unable to read file /etc/prometheus-secrets/litellm_token: open /etc/prometheus-secrets/litellm_token: no such file or directory' 
  stub_prometheus "${SCRATCH}/targets-litellm-nofile.json" "${SCRATCH}/metrics-clean.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/litellm-nofile.env"
  assert_eq "an unreadable credentials file is still a warning, not a failure" 0 "${status}"
  # Verbatim off /api/v1/targets on prom/prometheus:v3.16.0, the Get "url": prefix
  # and the open <path>: tail included: both arrive with escaped quotes, and a
  # reader that cuts the field at the first " byte loses everything after Get.
  assert_match "the lastError is quoted whole, prefix, quotes, path and all" \
    'lastError '"'"'Get "http://litellm:4000/metrics": unable to read authorization credentials: unable to read file /etc/prometheus-secrets/litellm_token: open /etc/prometheus-secrets/litellm_token: no such file or directory'"'"'' "${output}"
  assert_match "the unreadable-credentials shape is the one that names the token file" \
    'warning: that lastError is the bearer, not the proxy: /etc/prometheus-secrets/litellm_token in the prometheus container has to hold the key' "${output}"
  assert_not_match "metrics auth is never offered as the fix" \
    'require_auth_for_metrics_endpoint' "${output}"
  assert_summary_is_last_line
}

@test "a refused litellm connection blames the proxy and never the token file" {
  write_env_file "${SCRATCH}/litellm-refused.env"
  write_targets_body "${SCRATCH}/targets-litellm-refused.json" up down "" \
    'Get \"http://litellm:4000/metrics\": dial tcp 172.18.0.5:4000: connect: connection refused' 
  stub_prometheus "${SCRATCH}/targets-litellm-refused.json" "${SCRATCH}/metrics-clean.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/litellm-refused.env"
  assert_eq "a proxy that is down is still a warning, not a failure" 0 "${status}"
  assert_match "the refused connection is quoted as the target recorded it" \
    'lastError '"'"'Get "http://litellm:4000/metrics": dial tcp 172.18.0.5:4000: connect: connection refused'"'"'' "${output}"
  assert_match "the pointer says the proxy is the thing that is down" \
    'warning: that lastError is the proxy itself, not the bearer file: litellm has to be up and answering litellm:4000 on the project network' "${output}"
  assert_not_match "a dead proxy is never sent to check the token file" \
    '/etc/prometheus-secrets/litellm_token' "${output}"
  assert_summary_is_last_line
}

@test "a litellm lastError of no known shape names neither cause" {
  write_env_file "${SCRATCH}/litellm-unknown.env"
  write_targets_body "${SCRATCH}/targets-litellm-unknown.json" up down "" \
    'Get \"http://litellm:4000/metrics\": context deadline exceeded while reading body' 
  stub_prometheus "${SCRATCH}/targets-litellm-unknown.json" "${SCRATCH}/metrics-clean.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/litellm-unknown.env"
  assert_eq "an unrecognised cause is still a warning, not a failure" 0 "${status}"
  assert_match "the cause the target recorded is printed rather than guessed at" \
    'lastError '"'"'Get "http://litellm:4000/metrics": context deadline exceeded while reading body'"'"'' "${output}"
  assert_match "the pointer says the lastError is all this CLI has" \
    'warning: the lastError above is the only cause this CLI has for the litellm scrape' "${output}"
  assert_not_match "an unknown shape does not blame the token file" \
    '/etc/prometheus-secrets/litellm_token' "${output}"
  assert_summary_is_last_line
}

@test "an escaped tab in the lastError still prints as one target line" {
  write_env_file "${SCRATCH}/litellm-tab.env"
  # encoding/json writes a control byte as a two-byte escape, so this is the
  # spelling a real body carries - and the one that could still split one target
  # across two tally rows if the reader folded only the raw byte.
  write_targets_body "${SCRATCH}/targets-litellm-tab.json" up down "" \
    'Get \"http://litellm:4000/metrics\": dial tcp 172.18.0.5:4000:\tconnect: connection refused' 
  stub_prometheus "${SCRATCH}/targets-litellm-tab.json" "${SCRATCH}/metrics-clean.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/litellm-tab.env"
  assert_eq "an escaped tab is no more fatal than the message around it" 0 "${status}"
  assert_match "the escape is folded to a space in the warning" \
    'lastError '"'"'Get "http://litellm:4000/metrics": dial tcp 172.18.0.5:4000: connect: connection refused'"'"'' "${output}"
  local lines
  lines="$(printf '%s\n' "${output}" | grep -c '^warning: prometheus target job')"
  assert_eq "one red target is exactly one warning line" 1 "${lines}"
  assert_summary_is_last_line
}

@test "raw control bytes in a lastError never reach the report" {
  write_env_file "${SCRATCH}/litellm-ctl.env"
  # A scraped peer chooses its own failure text, and the CLI prints it. Raw ESC,
  # BEL and CR have to be stripped, or this check hands a terminal-control
  # sequence straight to whatever shell the operator is reading it in.
  local ctl
  ctl="$(printf 'Get \\"http://litellm:4000/metrics\\": \033[31mRED\007\rrefused')"
  write_targets_body "${SCRATCH}/targets-litellm-ctl.json" up down "" "${ctl}"
  stub_prometheus "${SCRATCH}/targets-litellm-ctl.json" "${SCRATCH}/metrics-clean.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/litellm-ctl.env"
  assert_eq "a control byte is no more fatal than the message around it" 0 "${status}"
  assert_match "the text around the control bytes still arrives" "\[31mRED +refused" "${output}"
  local stray
  stray="$(printf '%s' "${output}" | tr -d '\n' | tr -dc '\000-\037\177' | wc -c | tr -d '[:space:]')"
  assert_eq "no control byte but the line breaks survives into the report" 0 "${stray}"
  local lines
  lines="$(printf '%s\n' "${output}" | grep -c '^warning: prometheus target job')"
  assert_eq "one red target is still exactly one warning line" 1 "${lines}"
  assert_summary_is_last_line
}

@test "a red target from another job does not blame the token file" {
  write_env_file "${SCRATCH}/prom-down.env"
  write_targets_body "${SCRATCH}/targets-prom-down.json" down up \
    'Get \"http://127.0.0.1:9090/metrics\": dial tcp 127.0.0.1:9090: connect: connection refused' 
  stub_prometheus "${SCRATCH}/targets-prom-down.json" "${SCRATCH}/metrics-clean.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/prom-down.env"
  assert_eq "a red target is still a warning, not a failure" 0 "${status}"
  assert_match "the red job is named with its own lastError" \
    'warning: prometheus target job '"'"'prometheus'"'"' reports '"'"'down'"'"', not up: lastError '"'"'Get "http://127.0.0.1:9090/metrics": dial tcp 127.0.0.1:9090: connect: connection refused'"'"'' "${output}"
  assert_not_match "the litellm pointer is not attached to a job that has no bearer" \
    'litellm has to be up and answering' "${output}"
  assert_not_match "the token file is not mentioned for a job that has none" \
    '/etc/prometheus-secrets/litellm_token' "${output}"
  assert_summary_is_last_line
}

@test "failed samples to Mimir are a warning that names the counter" {
  write_env_file "${SCRATCH}/push.env"
  printf '%s\n' \
    '# TYPE prometheus_remote_storage_samples_failed_total counter' \
    'prometheus_remote_storage_samples_failed_total{queue="0"} 7' >"${SCRATCH}/metrics-failing.txt"
  stub_prometheus "${SCRATCH}/targets-up.json" "${SCRATCH}/metrics-failing.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/push.env"
  assert_eq "a failing push is a warning, not a failure" 0 "${status}"
  assert_match "the counter and Mimir are named" \
    'warning: prometheus_remote_storage_samples_failed_total=7: .*Mimir' "${output}"
  assert_not_match "a clean push is not also reported" \
    'ok: prometheus remote_write' "${output}"
}

@test "a Prometheus with no remote_write is a warning that names remote_write" {
  write_env_file "${SCRATCH}/no-write.env"
  printf '%s\n' '# TYPE prometheus_build_info gauge' \
    'prometheus_build_info{version="3.16.0"} 1' >"${SCRATCH}/metrics-nowrite.txt"
  stub_prometheus "${SCRATCH}/targets-up.json" "${SCRATCH}/metrics-nowrite.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/no-write.env"
  assert_eq "a missing counter is a warning, not a failure" 0 "${status}"
  assert_match "the warning names remote_write" \
    'warning: prometheus exposes no prometheus_remote_storage_samples_failed_total: .*remote_write' "${output}"
}

@test "a Prometheus that will not answer is one error and skips the data flow" {
  write_env_file "${SCRATCH}/dead.env"
  export CURL_PLAN="http://127.0.0.1:9090/-/healthy|0|;http://127.0.0.1:3005/api/health|0|;\
http://127.0.0.1:9090/api/v1/targets|7|;http://127.0.0.1:9090/metrics|7|;\
http://127.0.0.1:9090/api/v1/rules|7|;${SEARCH_PLAN}"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/dead.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a dead Prometheus must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the dead API is named once" \
    'error: Prometheus did not answer http://127.0.0.1:9090/api/v1/targets' "${output}"
  assert_not_match "the metrics probe is not tried on top of it" \
    'did not answer http://127.0.0.1:9090/metrics' "${output}"
  assert_not_match "no target tally is invented" 'scrape targets:' "${output}"
  assert_summary_is_last_line
}

@test "an enrolled fleet with no sparks.json gets one note and still exits 0" {
  write_env_file "${SCRATCH}/spark.env"
  write_spark_root "${SCRATCH}/sparkroot"
  export REPO_ROOT="${SCRATCH}/sparkroot"
  export SPARK_MONITOR_ENABLED=true
  run bash "${SCRIPT}" --env-file "${SCRATCH}/spark.env"
  assert_eq "a missing file-SD document is not a failure" 0 "${status}"
  local lines
  lines="$(printf '%s\n' "${output}" | grep -c 'sparks\.json' || true)"
  assert_eq "exactly one line names it" 1 "${lines}"
  assert_match "the note names the file it is missing" \
    '^note: .*observability/spark-targets/sparks\.json does not exist' "${output}"
  assert_match "the note names how Prometheus reads it" \
    'file_sd_configs in observability/prometheus/prometheus\.yml' "${output}"
  assert_match "the note names the three jobs that read it" \
    'spark-node :149, blackbox-spark :171, blackbox-spark-models :195' "${output}"
  assert_match "the note names the command that writes it" \
    "bazelisk run //scripts:spark-monitor -- --targets" "${output}"
  assert_match "the tally it sits beside is still reported" \
    'ok: prometheus scrape targets: all 7 up' "${output}"
  assert_match "and the run still reports nothing failed" \
    '^summary: [0-9]+ ok, [0-9]+ warnings, 0 failed$' "${output}"
  assert_summary_is_last_line
}

@test "a sparks.json that landed is not talked about again" {
  write_env_file "${SCRATCH}/spark.env"
  write_spark_root "${SCRATCH}/sparkroot"
  mkdir -p "${SCRATCH}/sparkroot/observability/spark-targets"
  printf '%s\n' '[{"targets":["10.0.0.11:9101"],"labels":{"box":"spark-1"}}]' \
    >"${SCRATCH}/sparkroot/observability/spark-targets/sparks.json"
  export REPO_ROOT="${SCRATCH}/sparkroot"
  export SPARK_MONITOR_ENABLED=true
  run bash "${SCRIPT}" --env-file "${SCRATCH}/spark.env"
  assert_eq "a published target set exits 0" 0 "${status}"
  assert_not_match "nothing is said about the file-SD document" 'sparks\.json' "${output}"
  assert_match "the tally is untouched" 'ok: prometheus scrape targets: all 7 up' "${output}"
  assert_summary_is_last_line
}

@test "with the Spark flag off an unenrolled fleet stays silent" {
  write_env_file "${SCRATCH}/spark.env"
  write_spark_root "${SCRATCH}/sparkroot"
  export REPO_ROOT="${SCRATCH}/sparkroot"
  export SPARK_MONITOR_ENABLED=false
  run bash "${SCRIPT}" --env-file "${SCRATCH}/spark.env"
  assert_eq "the shipped default exits 0" 0 "${status}"
  assert_not_match "no line names the file-SD document" 'sparks\.json' "${output}"
  assert_summary_is_last_line
}

@test "a down endpoint is a failure that names the URL" {
  write_env_file "${SCRATCH}/grafana-down.env"
  export CURL_PLAN="http://127.0.0.1:9090/-/healthy|0|;http://127.0.0.1:3005/api/health|22|;\
${RULES_PLAN};http://127.0.0.1:3005/api/search?type=dash-db|22|"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/grafana-down.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a down Grafana must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the dead endpoint is named with its URL" \
    'error: grafana did not answer at http://127.0.0.1:3005/api/health' "${output}"
  assert_match "the healthy one is still reported" \
    'ok: prometheus answers at http://127.0.0.1:9090/-/healthy' "${output}"
}

@test "an in-network probe that answers 503 fails the run" {
  write_env_file "${SCRATCH}/mimir-down.env"
  printf '%s\n' 'http://mimir:8080/ready=503' >>"${SCRATCH}/codes"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/mimir-down.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a 503 from Mimir must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the service and its code are named" \
    'error: mimir is not ready: 503 from http://mimir:8080/ready' "${output}"
  assert_match "the other probes still answered" 'ok: loki is ready: 200' "${output}"
}

@test "an exporter whose port refuses the connection says its container is not running" {
  write_env_file "${SCRATCH}/refused.env"
  export CURL_PLAN="${EXPORTER_PLAN};${RULES_PLAN};${SEARCH_PLAN};http://127.0.0.1:9101/metrics|7||"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/refused.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a refused exporter port must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the refused service names its port and why" \
    'error: node_exporter is not listening on 127.0.0.1:9101: connection refused, so its container is not running' "${output}"
  assert_match "the fix is named" '//scripts:dev-stack -- up' "${output}"
  assert_not_match "a refused port is not also called a wrong path" \
    'node_exporter answered 404' "${output}"
  assert_match "the other exporters are still probed" \
    'ok: cadvisor answers at http://127.0.0.1:9290/metrics and exposes container_last_seen series' "${output}"
  assert_summary_is_last_line
}

@test "an exporter that answers 200 without its family is a warning, not a failure" {
  write_env_file "${SCRATCH}/no-family.env"
  export CURL_PLAN="${EXPORTER_PLAN};${RULES_PLAN};${SEARCH_PLAN};http://127.0.0.1:9290/metrics|0|${SCRATCH}/metrics-no-family.txt|200"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/no-family.env"
  assert_eq "an exporter up and misconfigured must not fail the run" 0 "${status}"
  assert_match "the warning names the missing family and the collector" \
    'warning: cadvisor answered 200 at http://127.0.0.1:9290/metrics but exposes no series starting with container_last_seen: .*collector.* is off' "${output}"
  assert_not_match "that exporter is not also counted as answering" \
    'ok: cadvisor answers at' "${output}"
  assert_summary_is_last_line
}

@test "an exporter answering 404 says the port or the path is wrong" {
  write_env_file "${SCRATCH}/wrong-path.env"
  export CURL_PLAN="${EXPORTER_PLAN};${RULES_PLAN};${SEARCH_PLAN};http://127.0.0.1:9115/metrics|0||404"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/wrong-path.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a 404 from an exporter port must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the 404 is named with its path" \
    'error: blackbox_exporter answered 404 at http://127.0.0.1:9115/metrics: .*serves no /metrics' "${output}"
  assert_not_match "a 404 is not reported as a missing family" \
    'no series starting with blackbox_exporter_' "${output}"
  assert_match "the prober round-trip is still answered" \
    'ok: blackbox_exporter ran the spark_models probe' "${output}"
  assert_summary_is_last_line
}

@test "a prober that refuses the connection is an error the round-trip makes visible" {
  write_env_file "${SCRATCH}/prober-down.env"
  export CURL_PLAN="${EXPORTER_PLAN};${RULES_PLAN};${SEARCH_PLAN};http://127.0.0.1:9115/probe?module=spark_health&target=http://prometheus:9090/-/healthy|7||"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/prober-down.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a prober that cannot be reached must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the prober's own port and verb are named" \
    'error: blackbox_exporter is not listening on 127.0.0.1:9115: connection refused, so no probe of any module can have run' "${output}"
  assert_match "the module that was never asked is still reported green" \
    'ok: blackbox_exporter ran the spark_models probe of http://prometheus:9090/-/healthy: probe_success 1' "${output}"
  assert_summary_is_last_line
}

@test "a blackbox module that never loaded is named instead of called a red target" {
  write_env_file "${SCRATCH}/dead-module.env"
  export CURL_PLAN="${EXPORTER_PLAN};${RULES_PLAN};${SEARCH_PLAN};http://127.0.0.1:9115/probe?module=spark_health&target=http://prometheus:9090/-/healthy|0|${SCRATCH}/probe-no-module.txt|400"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/dead-module.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a module the prober does not know must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the unknown module is named with the code" \
    'error: blackbox_exporter does not know the module spark_health: 400 from' "${output}"
  assert_match "blackbox's own complaint is quoted" 'Target module spark_health not found' "${output}"
  assert_not_match "a dead module is not reported as a red probe" 'came back red' "${output}"
  assert_summary_is_last_line
}

@test "a probe that came back red is a warning that names the module and its target" {
  write_env_file "${SCRATCH}/probe-red.env"
  export CURL_PLAN="${EXPORTER_PLAN};${RULES_PLAN};${SEARCH_PLAN};http://127.0.0.1:9115/probe?module=spark_models&target=http://prometheus:9090/-/healthy|0|${SCRATCH}/probe-red.txt|200"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/probe-red.env"
  assert_eq "a red probe is the prober working, so it must not fail the run" 0 "${status}"
  assert_match "the warning names the module, the target and both series" \
    'warning: blackbox_exporter ran the spark_models probe of http://prometheus:9090/-/healthy and it came back red: probe_success 0, probe_http_status_code 0' "${output}"
  assert_not_match "the red module is not also counted green" \
    'ok: blackbox_exporter ran the spark_models probe' "${output}"
  assert_summary_is_last_line
}

@test "a prober that answers 200 with no probe_success series says it is probing nothing" {
  write_env_file "${SCRATCH}/probe-nothing.env"
  export CURL_PLAN="${EXPORTER_PLAN};${RULES_PLAN};${SEARCH_PLAN};http://127.0.0.1:9115/probe?module=spark_health&target=http://prometheus:9090/-/healthy|0|${SCRATCH}/probe-no-series.txt|200"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/probe-nothing.env"
  assert_eq "a prober that probes nothing is a warning, not a failure" 0 "${status}"
  assert_match "the finding says no probe_success came back" \
    'warning: blackbox_exporter answered 200 at .* but sent no probe_success series: the prober is up and probing nothing' "${output}"
  assert_summary_is_last_line
}

@test "an exporter Prometheus does not collect is a warning that names the job" {
  write_env_file "${SCRATCH}/uncollected.env"
  stub_prometheus "${SCRATCH}/targets-up.json" "${SCRATCH}/metrics-clean.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/uncollected.env"
  assert_eq "nobody scraping an exporter is a warning, not a failure" 0 "${status}"
  assert_match "the missing job is named and told what it costs" \
    'warning: prometheus collects no cadvisor job: .*nobody scrapes it.*panel will be empty' "${output}"
  assert_match "the exporter itself is still reported as answering" \
    'ok: cadvisor answers at http://127.0.0.1:9290/metrics' "${output}"
  assert_not_match "a job the target list carries is not blamed" 'collects no prometheus job' "${output}"
  assert_summary_is_last_line
}

@test "a switched-off bundle probes no exporter port at all" {
  write_env_file "${SCRATCH}/off-exporters.env" 'OBSERVABILITY_ENABLED=false'
  run bash "${SCRIPT}" --env-file "${SCRATCH}/off-exporters.env"
  assert_eq "the off path still exits 0" 0 "${status}"
  assert_match "the exporters section skipped itself with the reason" \
    'note: skipped: the bundle is switched off, so no exporter port is expected to be bound' "${output}"
  assert_eq "no exporter was probed" "0" "$(stub_log_count curl)"
}

@test "every rule file prometheus.yml names is loaded and reported with its rules" {
  [ -r "${PROMETHEUS_YML}" ] || skip "prometheus.yml is not readable in this run"
  write_env_file "${SCRATCH}/rules.env"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/rules.env"
  assert_eq "a fully loaded rule set exits 0" 0 "${status}"
  assert_match "the rules section ran" '== rules ==' "${output}"
  local file count=0
  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    count=$((count + 1))
    assert_match "${file} is reported loaded with rules in it" \
      "ok: ${file} is loaded: [1-9][0-9]* group\\(s\\), [1-9][0-9]* rule\\(s\\)" "${output}"
  done < <(sed -n '/^rule_files:/,/^[^ ]/p' "${PROMETHEUS_YML}" |
    sed -n 's/^[[:space:]]*-[[:space:]]*\(.*\)/\1/p')
  [ "${count}" -gt 0 ] || {
    printf 'FAIL: prometheus.yml named no rule file, so the loop proved nothing\n' >&2
    return 1
  }
  assert_summary_is_last_line
}

@test "a rule file prometheus.yml names that never loaded is an error" {
  [ -r "${PROMETHEUS_YML}" ] || skip "prometheus.yml is not readable in this run"
  local missing
  missing="$(sed -n '/^rule_files:/,/^[^ ]/p' "${PROMETHEUS_YML}" |
    sed -n 's/^[[:space:]]*-[[:space:]]*\(.*\)/\1/p' | tail -n 1)"
  [ -n "${missing}" ] || skip "prometheus.yml names no rule file to withhold"
  write_env_file "${SCRATCH}/rules-missing.env"
  write_rules_body "${SCRATCH}/rules-one-missing.json" "missing:${missing}"
  stub_rules "${SCRATCH}/rules-one-missing.json"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/rules-missing.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a rule file that never loaded must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the file that did not load is named" \
    "error: ${missing} is named by observability/prometheus/prometheus.yml but Prometheus loaded no group from it" "${output}"
  assert_match "the silence it causes is said plainly" 'every alert in that file is silent' "${output}"
  assert_match "the other rule files are still reported" \
    'ok: rules/stack\.rules\.yml is loaded' "${output}"
  assert_match "the summary counts the failure" \
    '^summary: [0-9]+ ok, [0-9]+ warnings, [1-9][0-9]* failed$' "${output}"
  assert_summary_is_last_line
}

@test "a rule file that loaded with no rule in it is an error" {
  [ -r "${PROMETHEUS_YML}" ] || skip "prometheus.yml is not readable in this run"
  local target
  target="$(sed -n '/^rule_files:/,/^[^ ]/p' "${PROMETHEUS_YML}" |
    sed -n 's/^[[:space:]]*-[[:space:]]*\(.*\)/\1/p' | head -n 1)"
  [ -n "${target}" ] || skip "prometheus.yml names no rule file to empty out"
  write_env_file "${SCRATCH}/rules-empty.env"
  write_rules_body "${SCRATCH}/rules-empty.json" "empty:${target}"
  stub_rules "${SCRATCH}/rules-empty.json"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/rules-empty.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a rule file that ships nothing must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the empty file is named with what it loaded" \
    "error: ${target} loaded 1 group\\(s\\) holding 0 rules" "${output}"
  assert_match "the finding says the alerts can never fire" \
    'no alert can ever fire from it' "${output}"
  assert_not_match "an empty file is not also counted as loaded" \
    "ok: ${target} is loaded" "${output}"
  assert_summary_is_last_line
}

@test "a Prometheus that will not answer for its rules is a warning that names the profile" {
  write_env_file "${SCRATCH}/rules-down.env"
  export CURL_PLAN="${CURL_PLAN};http://127.0.0.1:9090/api/v1/rules|7||"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/rules-down.env"
  assert_eq "a bundle that is simply not up must not fail the run" 0 "${status}"
  assert_match "the warning names the port and the profile" \
    'warning: no Prometheus is listening on 127\.0\.0\.1:9090: .*observability compose profile' "${output}"
  assert_match "the fix is named" '//scripts:dev-stack -- up' "${output}"
  assert_not_match "no rule file is blamed on top of it" \
    'but Prometheus loaded no group from it' "${output}"
  assert_summary_is_last_line
}

@test "a switched-off bundle checks neither the rule files nor the dashboards" {
  write_env_file "${SCRATCH}/off-rules.env" 'OBSERVABILITY_ENABLED=false'
  run bash "${SCRIPT}" --env-file "${SCRATCH}/off-rules.env"
  assert_eq "the off path still exits 0" 0 "${status}"
  assert_match "the rules section skipped itself with the reason" \
    'note: skipped: the bundle is switched off, so no rule file is expected to be loaded' "${output}"
  assert_match "the dashboards section skipped itself with the reason" \
    'note: skipped: the bundle is switched off, so no dashboard is expected to be registered' "${output}"
  assert_eq "neither API was asked" "0" "$(stub_log_count curl)"
}

@test "every dashboard the repo ships is proven registered in Grafana" {
  [ -d "${DASHBOARD_DIR}" ] || skip "the dashboard tree is not in this run"
  write_env_file "${SCRATCH}/dashboards.env"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/dashboards.env"
  assert_eq "a fully registered set exits 0" 0 "${status}"
  assert_match "the dashboards section ran" '== dashboards ==' "${output}"
  local file uid count=0
  for file in "${DASHBOARD_DIR}"/*.json; do
    [ -f "${file}" ] || continue
    uid="$(sed -n 's/^  "uid": "\([^"]*\)".*/\1/p' "${file}" | head -n 1)"
    [ -n "${uid}" ] || continue
    count=$((count + 1))
    assert_match "$(basename "${file}") is registered as ${uid}" \
      "ok: ${uid} .* is registered in Grafana" "${output}"
  done
  [ "${count}" -gt 0 ] || {
    printf 'FAIL: no shipped dashboard names a uid, so the loop proved nothing\n' >&2
    return 1
  }
  assert_summary_is_last_line
}

@test "a dashboard git ships that Grafana never imported is an error named by its uid" {
  [ -d "${DASHBOARD_DIR}" ] || skip "the dashboard tree is not in this run"
  local file uid drop="" keep=""
  local -a uids=()
  for file in "${DASHBOARD_DIR}"/*.json; do
    [ -f "${file}" ] || continue
    uid="$(sed -n 's/^  "uid": "\([^"]*\)".*/\1/p' "${file}" | head -n 1)"
    [ -n "${uid}" ] && uids+=("${uid}")
  done
  [ "${#uids[@]}" -gt 1 ] || skip "the tree needs two dashboards to prove one can go missing"
  drop="${uids[0]}"
  keep="${uids[-1]}"
  write_env_file "${SCRATCH}/dashboards-missing.env"
  write_search_body "${SCRATCH}/search-one-missing.json" "${drop}"
  stub_grafana_search "${SCRATCH}/search-one-missing.json"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/dashboards-missing.env"
  [ "${status}" -ne 0 ] || {
    printf 'FAIL: a dashboard on disk and not in Grafana must fail the run, got %s\n' "${status}" >&2
    return 1
  }
  assert_match "the file and its uid are named" \
    "error: .*\.json is on disk and not in Grafana: ${drop}" "${output}"
  assert_match "the provider is named as the thing that never imported it" \
    'the file provider never imported it' "${output}"
  assert_match "the other dashboards are still reported" \
    "ok: ${keep} .* is registered in Grafana" "${output}"
  assert_match "the summary counts the failure" \
    '^summary: [0-9]+ ok, [0-9]+ warnings, [1-9][0-9]* failed$' "${output}"
  assert_summary_is_last_line
}

@test "a Grafana that will not answer for its dashboards is a warning that says why" {
  [ -d "${DASHBOARD_DIR}" ] || skip "the dashboard tree is not in this run"
  write_env_file "${SCRATCH}/dashboards-down.env"
  export CURL_PLAN="${CURL_PLAN};http://127.0.0.1:3005/api/search?type=dash-db|7||"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/dashboards-down.env"
  assert_eq "a bundle that is simply not up must not fail the run" 0 "${status}"
  assert_match "the warning names the port and the profile" \
    'warning: no Grafana is listening on 127\.0\.0\.1:3005: .*observability compose profile' "${output}"
  assert_match "the unproven set is counted" 'dashboard file\(s\) in observability/grafana/dashboards' "${output}"
  assert_not_match "no single dashboard is blamed on top of it" \
    'is on disk and not in Grafana' "${output}"
  assert_summary_is_last_line
}

@test "the report grammar is the house vocabulary in the pinned order" {
  write_env_file "${SCRATCH}/grammar.env"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/grammar.env"
  local sections
  sections="$(printf '%s\n' "${output}" | grep -E '^== .* ==$' | tr '\n' ' ')"
  assert_eq "the nine sections print in order" \
    "== configuration == == log source == == compose render == == containers == == endpoints == == data flow == == exporters == == rules == == dashboards == " \
    "${sections}"
  assert_match "a phase line was printed" '-> curl http://127.0.0.1:9090/-/healthy' "${output}"
  assert_match "the finding prefixes are in use" '^ok: ' "${output}"
  assert_summary_is_last_line
}

@test "every function this CLI defines is named by this suite" {
  local -a fns=(
    resolve_repo_root
    find_lib
    usage
    usage_error
    key_requires_value
    key_state
    resolved_value
    compose_cmd
    probe_loopback
    probe_in_network
    fetch_with_code
    refused
    probe_exporter
    probe_prober
    targets_tally
    rule_files_from
    rules_tally
    dashboard_fields
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
  )
  local fn defined
  for fn in "${fns[@]}"; do
    assert_contains_file "observability-check.sh defines ${fn}" "${SCRIPT}" "^${fn}\\(\\) \\{"
  done
  defined="$(grep -cE '^[a-z_]+\(\) \{' "${SCRIPT}")"
  assert_eq "and no function is left unlisted" "${#fns[@]}" "${defined}"
}
