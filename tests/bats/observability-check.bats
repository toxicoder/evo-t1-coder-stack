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

# setup - resolve the checkout, write the two stubs, and lay out one healthy
# shape (six services rendered, six containers running, four in-network probes
# answering 200, every target up, nothing failed to Mimir) that individual tests
# narrow. Nothing from this process's environment is allowed to decide what the
# run reads, so every key the CLI consults is cleared first.
# Globals:
#   REPO_ROOT, SCRIPT, LIB, SCRATCH, PROJ, PATH
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
  unset DOCKER_CONFIG_FAIL DOCKER_PS_FAIL CURL_PLAN

  printf '%s\n' 'services: {}' >"${PROJ}/docker-compose.yml"
  export COMPOSE_FILE="${PROJ}/docker-compose.yml"

  printf '%s\n' prometheus loki mimir tempo grafana alloy >"${SCRATCH}/services"
  : >"${SCRATCH}/ps"
  : >"${SCRATCH}/state"
  local service
  for service in prometheus loki mimir tempo grafana alloy; do
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
  printf '%s\n' \
    '# TYPE prometheus_remote_storage_samples_failed_total counter' \
    'prometheus_remote_storage_samples_failed_total{queue="0"} 0' >"${SCRATCH}/metrics-clean.txt"
  stub_prometheus "${SCRATCH}/targets-up.json" "${SCRATCH}/metrics-clean.txt"

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
# plan of `url|exit-code|body-file` entries says how that URL answers. A URL the
# plan does not name answers 200 with an empty body, and a non-zero exit code
# stands in for what curl's own -f does to a non-2xx.
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
body=""
out=""
prev=""
for arg in "$@"; do
  if [ "${prev}" = "-o" ]; then out="${arg}"; fi
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
    e_body="${rest#*|}"
    if [ "${e_url}" = "${url}" ]; then
      rc="${e_rc}"
      body="${e_body}"
    fi
  done
fi
if [ "${rc}" != "0" ]; then
  printf 'curl: (%s) The requested URL returned an error\n' "${rc}" >&2
  exit 1
fi
if [ -n "${out}" ]; then
  if [ -n "${body}" ] && [ -f "${body}" ]; then cat "${body}" >"${out}"; else : >"${out}"; fi
elif [ -n "${body}" ] && [ -f "${body}" ]; then
  cat "${body}"
fi
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

# write_targets_body <path> <health-a> <health-b> - a Prometheus /api/v1/targets
# body with two active targets, one per health value, in the field order
# Prometheus itself emits (labels before health).
# Globals:
#   None
# Arguments:
#   $1 - file to write; $2 - health of the prometheus job; $3 - health of the litellm job
# Outputs:
#   The body file
# Returns:
#   0
write_targets_body() {
  printf '%s\n' "{\"status\":\"success\",\"data\":{\"activeTargets\":[\
{\"discoveredLabels\":{\"__address__\":\"127.0.0.1:9090\"},\"labels\":{\"instance\":\"127.0.0.1:9090\",\"job\":\"prometheus\"},\"scrapeUrl\":\"http://127.0.0.1:9090/metrics\",\"lastError\":\"\",\"health\":\"$2\"},\
{\"discoveredLabels\":{\"__address__\":\"litellm:4000\"},\"labels\":{\"instance\":\"litellm:4000\",\"job\":\"litellm\"},\"scrapeUrl\":\"http://litellm:4000/metrics\",\"lastError\":\"\",\"health\":\"$3\"}\
],\"droppedTargets\":[]}}" >"${1}"
}

# stub_prometheus <targets-file> <metrics-file> - point the curl plan at the two
# bodies the data flow section reads; the loopback health endpoints keep answering
# 200 with an empty body.
# Globals:
#   SCRATCH
# Arguments:
#   $1 - targets body; $2 - metrics body
# Outputs:
#   CURL_PLAN
# Returns:
#   0
stub_prometheus() {
  export CURL_PLAN="http://127.0.0.1:9090/-/healthy|0|;http://127.0.0.1:3005/api/health|0|;\
http://127.0.0.1:9090/api/v1/targets|0|${1};http://127.0.0.1:9090/metrics|0|${2}"
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
  for service in prometheus loki mimir tempo grafana alloy; do
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
  assert_match "all targets are up" 'ok: prometheus scrape targets: all 2 up' "${output}"
  assert_match "remote_write is clean" \
    'ok: prometheus remote_write: no failed samples to Mimir' "${output}"
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
  assert_match "the other five are still reported" \
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
  assert_not_match "the six services are not each blamed on top of it" \
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
  assert_eq "docker was never called" "0" "$(stub_log_count docker)"
  assert_summary_is_last_line
}

@test "a down target is a warning that names its job and still exits 0" {
  write_env_file "${SCRATCH}/down.env"
  write_targets_body "${SCRATCH}/targets-down.json" up down
  stub_prometheus "${SCRATCH}/targets-down.json" "${SCRATCH}/metrics-clean.txt"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/down.env"
  assert_eq "a red target is a warning, not a failure" 0 "${status}"
  assert_match "the down job is named" \
    "warning: prometheus target job 'litellm' reports 'down', not up" "${output}"
  assert_not_match "the up job is not named" "job 'prometheus' reports" "${output}"
  assert_match "the tally is printed" 'ok: prometheus scrape targets: 1 of 2 up' "${output}"
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
http://127.0.0.1:9090/api/v1/targets|7|;http://127.0.0.1:9090/metrics|7|"
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

@test "a down endpoint is a failure that names the URL" {
  write_env_file "${SCRATCH}/grafana-down.env"
  export CURL_PLAN="http://127.0.0.1:9090/-/healthy|0|;http://127.0.0.1:3005/api/health|22|"
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

@test "the report grammar is the house vocabulary in the pinned order" {
  write_env_file "${SCRATCH}/grammar.env"
  run bash "${SCRIPT}" --env-file "${SCRATCH}/grammar.env"
  local sections
  sections="$(printf '%s\n' "${output}" | grep -E '^== .* ==$' | tr '\n' ' ')"
  assert_eq "the six sections print in order" \
    "== configuration == == log source == == compose render == == containers == == endpoints == == data flow == " \
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
    targets_tally
    check_configuration
    check_log_source
    check_compose_render
    check_containers
    check_endpoints
    check_data_flow
    finish
  )
  local fn defined
  for fn in "${fns[@]}"; do
    assert_contains_file "observability-check.sh defines ${fn}" "${SCRIPT}" "^${fn}\\(\\) \\{"
  done
  defined="$(grep -cE '^[a-z_]+\(\) \{' "${SCRIPT}")"
  assert_eq "and no function is left unlisted" "${#fns[@]}" "${defined}"
}
