#!/usr/bin/env bats
#
# ## observability-query.bats - hermetic coverage for scripts/observability-query.sh.
#
# The contract pinned here is the one a coding agent branches on, not the one the
# code finds easiest: the three states that must never collapse into each other
# (profile off, no data, error), the label set a log query may name and the refusal
# that has to answer before any request when it names another, the credential that
# is read from a file and must appear nowhere in what this prints or in what a stub
# recorded, and the `summary: N ok, W warnings, F failed` line that closes a run and
# is what a caller greps.
#
# Hermetic by construction. setup() shadows `curl` and `docker` with one private
# bin/ directory prepended to PATH: the CLI shells out to those two and to nothing
# else that could reach a socket or a daemon, while the coreutils it pipes through
# (grep, sed, tr, wc, cat, date, basename, dirname) stay the host's. No test opens
# a socket, pulls an image, or needs the observability profile enabled anywhere.
#
# The two stubs are written into this test's tmpdir rather than taken from
# tests/bats/tool_stubs/, because the shared docker stub answers compose verbs and
# has no `docker run` case - the one-shot curlimages/curl container this CLI uses
# for the unpublished backends needs a plan keyed on the URL inside the container.
#
# The whole suite skips while scripts/observability-query.sh is absent: a suite for
# a script that does not exist yet has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_observability_query_test   (from any cwd)
# Safety: stubs and canned bodies only. No live service, no Docker, no network, no
# credential outside this test's tmpdir, and no file written outside it.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
LIB=""
SCRATCH=""
PROJ=""
TOKEN=""

# The read-only service-account value this suite mints into the fixture file. It is
# inert by construction (no real key shape) and is one literal on purpose, so every
# "the credential never appears" assertion scans for the same bytes a leak would
# carry, and the redaction test can plant it in a response body and watch for the
# marker that has to come back instead.
STUB_CRED="svc-stub-grafana-readonly-value"

# The provisioned datasource UIDs, as observability/grafana/provisioning/
# datasources/stack.yaml:15,32,46,57 declares them and as
# scripts/lib/observability_query.sh transcribes them.
DS_UIDS=(prometheus mimir loki tempo)

# The answer every URL gives unless a test's plan_for() line claims it first: 200
# with one row in it, which is the "the bundle answered" state every test starts on.
PLAN_DEFAULT='*	0	200	{"data":{"result":[{"stream":{"container":"coder"},"values":[["1","hi"]]},"metric":{"job":"stack"}}]}}'

# Every helper this suite's subject declares, so one test can pin that each is
# reachable by name: tests/shell_inventory.sh fails the gate for a production
# function no test names, and this list is where this CLI's are named.
CLI_HELPERS=(obsq_resolve_root obsq_find_lib usage usage_error obsq_key
  obsq_resolve_base_url profile_switched_off obsq_report_profile_off
  obsq_require_token obsq_fetch
  obsq_fetch_in_network obsq_emit obsq_read_body obsq_report_answer
  run_logs run_metrics run_alerts run_dashboards run_search run_self_test finish)
LIB_HELPERS=(obsq_allowed_labels obsq_assert_ascii obsq_logql_label_names
  obsq_logql_rejects obsq_urlencode obsq_since_seconds obsq_validate_base_url
  obsq_datasource obsq_query_path obsq_labels_path obsq_read_token obsq_redact
  obsq_is_refused obsq_is_no_data obsq_answer_shape obsq_result_count)

# setup - resolve the checkout, write the two stubs, mint the fixture credential,
# and lay out the one shape every test starts from: the profile on, the dotenv
# holding the two ports the CLI reads, the token file present and readable. Nothing
# from this process's environment is allowed to decide what the run reads, so every
# key the CLI consults is cleared first.
# Globals:
#   REPO_ROOT, SCRIPT, LIB, SCRATCH, PROJ, TOKEN, STUB_CRED, PATH
# Arguments:
#   None
# Outputs:
#   The private bin/, the fixture compose project, the stub plans, the token file
# Returns:
#   0, or a skip when the script or one of its libs is not in the tree
setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/observability-query.sh"
  LIB="${REPO_ROOT}/scripts/lib/observability_query.sh"
  if [ ! -f "${SCRIPT}" ] || [ ! -f "${LIB}" ]; then
    skip "scripts/observability-query.sh or its lib is not in the tree"
  fi

  SCRATCH="$(make_scratch)"
  PROJ="${SCRATCH}/stackproj"
  mkdir -p "${SCRATCH}/bin" "${PROJ}" "${SCRATCH}/stub-logs"
  export STUB_LOG="${SCRATCH}/stub-logs"
  write_curl_stub "${SCRATCH}/bin"
  write_docker_stub "${SCRATCH}/bin"
  PATH="$(with_path "${SCRATCH}/bin")"
  export PATH

  unset OBSERVABILITY_ENABLED ENV_FILE COMPOSE_FILE JSON_MODE
  unset GRAFANA_PORT OBS_ALERTMANAGER_PORT GRAFANA_QUERY_TOKEN_FILE
  unset GRAFANA_URL GRAFANA_BASE_URL
  unset CURL_PLAN DOCKER_PLAN DOCKER_UNAVAILABLE DOCKER_ERR CURL_ERR
  unset FAKE_BODY FAKE_CODE FAKE_RC STUB_CURL_OUT STUB_CURL_RC

  write_env_file "${PROJ}"
  export COMPOSE_FILE="${PROJ}/docker-compose.yml"

  TOKEN="${SCRATCH}/grafana-query-token"
  write_token_file "${TOKEN}" "${STUB_CRED}"
  export GRAFANA_QUERY_TOKEN_FILE="${TOKEN}"

  # The healthy default: every URL answers 200 with a body that holds one row, so a
  # test states only the answer it is about. plan_for() puts what a test asks for
  # ahead of this wildcard line, which stays the fallback at the end.
  : >"${SCRATCH}/plan-list"
  PLAN_LIST="${SCRATCH}/plan-list"
  printf '%s\n' "${PLAN_DEFAULT}" >"${SCRATCH}/plan"
  export CURL_PLAN="${SCRATCH}/plan"
  printf '%s\n' '*	0	200	[{"labels":{"alertname":"DiskFull"},"state":"active"}]' >"${SCRATCH}/docker-plan"
  export DOCKER_PLAN="${SCRATCH}/docker-plan"
}

# write_curl_stub <dir> - the curl stand-in. argv is the only input: a plan file of
# `url-substring<TAB>rc<TAB>http-code<TAB>body` lines says how each URL answers, the
# first match winning, and `*` matches any URL. A non-zero rc stands in for what
# curl's own transport failure looks like, complaint on stderr. The body goes to the
# -o file and the code to stdout, the way the real -o/-w pair splits them.
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
out="" want="" prev="" config=""
for a in "$@"; do
  case "${prev}" in
    -o) out="${a}" ;;
    -w) want="${a}" ;;
    --config) config="${a}" ;;
  esac
  prev="${a}"
done
# A credential that reached argv would land in the log above, which is exactly the
# leak the suite asserts against. Record only the config file's path.
if [ -n "${config}" ] && [ -n "${STUB_LOG:-}" ]; then printf 'config=%s\n' "${config}" >>"${STUB_LOG}/curl.log"; fi
rc=0 code=200 body=""
if [ -n "${CURL_PLAN:-}" ] && [ -f "${CURL_PLAN}" ]; then
  while IFS=$'\t' read -r p_needle p_rc p_code p_body; do
    [ -n "${p_needle}" ] || continue
    if [ "${p_needle}" = "*" ] || [[ "${url}" == *"${p_needle}"* ]]; then
      rc="${p_rc:-0}"
      code="${p_code:-200}"
      body="${p_body}"
      break
    fi
  done <"${CURL_PLAN}"
fi
if [ "${rc}" != "0" ]; then
  printf 'curl: (%s) %s\n' "${rc}" "${CURL_ERR:-Failed to connect to 127.0.0.1 port 3005 after 0 ms: Connection refused}" >&2
  exit "${rc}"
fi
if [ -n "${out}" ]; then
  printf '%s' "${body}" >"${out}"
else
  printf '%s' "${body}"
fi
if [ -n "${want}" ]; then printf '%s' "${code}"; fi
exit 0
STUB
  chmod 755 "${1}/curl"
}

# write_docker_stub <dir> - the docker stand-in for the one-shot container this CLI
# runs against an unpublished backend. Only `docker run ... <url>` is answered: the
# plan says what curl inside that container printed, and the stub reproduces its
# stdout exactly (the body, then the status code the -w write-out appended after a
# newline). Anything else is an argv this CLI must never build, so it fails loudly.
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
if [ "${1:-}" != "run" ]; then
  printf 'docker stub: unexpected argv: %s\n' "$*" >&2
  exit 9
fi
if [ -n "${DOCKER_UNAVAILABLE:-}" ]; then
  printf 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\n' >&2
  exit 1
fi
url="${*: -1}"
rc=0 code=200 body=""
if [ -n "${DOCKER_PLAN:-}" ] && [ -f "${DOCKER_PLAN}" ]; then
  while IFS=$'\t' read -r p_needle p_rc p_code p_body; do
    [ -n "${p_needle}" ] || continue
    if [ "${p_needle}" = "*" ] || [[ "${url}" == *"${p_needle}"* ]]; then
      rc="${p_rc:-0}"
      code="${p_code:-200}"
      body="${p_body}"
      break
    fi
  done <"${DOCKER_PLAN}"
fi
if [ "${rc}" != "0" ]; then
  printf '%s\n' "${DOCKER_ERR:-error: No such object: stackproj_default}" >&2
  exit "${rc}"
fi
printf '%s\n%s' "${body}" "${code}"
exit 0
STUB
  chmod 755 "${1}/docker"
}

# write_env_file <dir> - the fixture dotenv, with the two port keys the CLI reads
# and the profile key left on so the default run is the "bundle is up" run.
# Globals:
#   None
# Arguments:
#   $1 - the directory that holds the compose file and its .env
# Outputs:
#   <dir>/docker-compose.yml and <dir>/.env
# Returns:
#   0
write_env_file() {
  printf '%s\n' 'services: {}' >"${1}/docker-compose.yml"
  printf '%s\n' \
    'OBSERVABILITY_ENABLED=true' \
    'GRAFANA_PORT=3005' \
    'OBS_ALERTMANAGER_PORT=9093' >"${1}/.env"
}

# write_token_file <path> <value> - the minted credential, at the mode the boot step
# writes it.
# Globals:
#   None
# Arguments:
#   $1 - where to write it; $2 - the value to write
# Outputs:
#   The file, mode 0600
# Returns:
#   0
write_token_file() {
  (
    umask 077
    printf '%s\n' "${2}" >"${1}"
  )
  chmod 600 "${1}"
}

# assert_out <needle> / refute_out <needle> / assert_err <needle> - the house
# assertion shape: this repo ships no bats-assert, so stdout and stderr are matched
# by plain substring tests, the way tests/bats/observability-check.bats does it.
# Globals:
#   output, stderr
# Arguments:
#   $1 - the substring
# Outputs:
#   None
# Returns:
#   0 when the match is (or is not) there, 1 otherwise
assert_out() { [[ ${output} == *"${1}"* ]]; }
refute_out() { [[ ${output} != *"${1}"* ]]; }
assert_err() { [[ ${stderr} == *"${1}"* ]]; }
refute_err() { [[ ${stderr} != *"${1}"* ]]; }
assert_out_exact() { [ "${output}" = "${1}" ]; }

# run_cli [args...] - the CLI under test, with this test's PATH shadow in force.
# Globals:
#   SCRIPT
# Arguments:
#   $@ - the verb, its argument and the options
# Outputs:
#   The run's stdout in $output and its stderr in $stderr
# Returns:
#   Whatever the CLI returned, in $status
run_cli() {
  run --separate-stderr "${SCRIPT}" "$@"
}

# stub_said <needle> [logfile] - succeed when any recorded argv line holds <needle>,
# which is how a test asks what the CLI actually sent rather than what it printed.
# Globals:
#   STUB_LOG
# Arguments:
#   $1 - the substring to look for; $2 - optional log file name (default curl.log)
# Outputs:
#   None
# Returns:
#   0 when a stub saw it, 1 otherwise
stub_said() {
  local needle="$1" file="${2:-curl.log}"
  [ -f "${STUB_LOG}/${file}" ] || return 1
  grep -qF -- "${needle}" "${STUB_LOG}/${file}"
}

# assert_summary_last_line - pin the grammar: the counts line is the last thing the
# run printed, because that is the line a caller greps.
# Globals:
#   output
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0 when the summary closed the run, 1 otherwise
assert_summary_last_line() {
  local last=""
  last="$(printf '%s\n' "${output}" | grep -v '^[[:space:]]*$' | tail -n 1)"
  [[ ${last} =~ ^summary:\ [0-9]+\ ok,\ [0-9]+\ warnings,\ [0-9]+\ failed$ ]]
}

# plan_for <needle> <rc> <code> <body> - claim one URL shape for this test: the
# entry goes ahead of the default wildcard line, and the plan is rebuilt from the
# accumulated entries, so a test states the one endpoint it cares about and lets the
# wildcard answer everything else. The plan is first-match-wins, which is why an
# entry can never be appended behind the wildcard.
# Globals:
#   PLAN_LIST, CURL_PLAN, PLAN_DEFAULT
# Arguments:
#   $1 - the URL substring; $2 - transport exit status; $3 - the HTTP status code;
#   $4 - the body
# Outputs:
#   The rebuilt CURL_PLAN
# Returns:
#   0
plan_for() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"${PLAN_LIST}"
  cp "${PLAN_LIST}" "${CURL_PLAN}"
  printf '%s\n' "${PLAN_DEFAULT}" >>"${CURL_PLAN}"
}

@test 'usage answers the verb list and exits clean' {
  run_cli --help
  [ "${status}" -eq 0 ]
  assert_out 'logs QUERY'
  assert_out 'metrics QUERY'
  assert_out '--self-test'
  assert_out 'container, stream, job, stack'
}

@test 'a missing verb is a usage error answered before any request' {
  run_cli
  [ "${status}" -eq 2 ]
  refute_out 'summary:'
  [ ! -f "${STUB_LOG}/curl.log" ]
}

@test 'an unknown option is a usage error, not a result' {
  run_cli --traces
  [ "${status}" -eq 2 ]
  assert_err 'unknown option: --traces'
  [ ! -f "${STUB_LOG}/curl.log" ]
}

@test 'an unknown verb names the verbs it wanted instead of guessing' {
  run_cli traces '{container="a"}'
  [ "${status}" -eq 2 ]
  assert_err 'is not a verb'
  assert_err 'logs, metrics, alerts, dashboards, search'
}

@test 'logs and metrics refuse to run without a query' {
  run_cli logs
  [ "${status}" -eq 2 ]
  assert_err 'logs needs a query'
  run_cli metrics
  [ "${status}" -eq 2 ]
  assert_err 'metrics needs a query'
}

@test 'alerts and dashboards refuse an argument they cannot use' {
  run_cli alerts '{container="a"}'
  [ "${status}" -eq 2 ]
  assert_err 'alerts takes no argument'
  run_cli dashboards extra
  [ "${status}" -eq 2 ]
  assert_err 'dashboards takes no argument'
}

@test 'a zero timeout or limit is refused as the unbounded request it is' {
  run_cli logs '{container="coder"}' --timeout 0
  [ "${status}" -eq 2 ]
  assert_err '--timeout needs a whole number of seconds above zero'
  assert_err "'0'"
  run_cli logs '{container="coder"}' --timeout 00
  [ "${status}" -eq 2 ]
  assert_err "'00'"
  run_cli logs '{container="coder"}' --limit 0
  [ "${status}" -eq 2 ]
  assert_err '--limit needs a whole number of rows above zero'
  run_cli logs '{container="coder"}' --limit 00
  [ "${status}" -eq 2 ]
  assert_err "'00'"
  [ ! -f "${STUB_LOG}/curl.log" ]
}

@test 'a bad window, limit or source is answered as the typo it is' {
  run_cli metrics 'up' --since 7x
  [ "${status}" -eq 2 ]
  assert_err '--since needs a whole number'
  run_cli logs '{container="a"}' --limit 900
  [ "${status}" -eq 2 ]
  assert_err '--limit is capped at 500'
  run_cli metrics 'up' --source thanos
  [ "${status}" -eq 2 ]
  assert_err '--source is prometheus or mimir'
  [ ! -f "${STUB_LOG}/curl.log" ]
}

@test 'a label outside the guaranteed set is refused before the first request' {
  run_cli logs '{namespace="prod", container="coder"}'
  [ "${status}" -eq 2 ]
  assert_err 'namespace'
  assert_err 'the guaranteed set is container stream job stack'
  # Refusing after the request would have returned an empty result and looked
  # exactly like an empty box, so the request must never have been made.
  [ ! -f "${STUB_LOG}/curl.log" ]
}

@test 'invented labels are caught in every shape the selector allows' {
  local query
  for query in \
    '{cluster="a"}' \
    '{container="a"} |= "x" {pod="b"}' \
    '{container=~"coder.*", severity!="none"}' \
    '{container="a" !~ "x", trace_id="y"}'; do
    run_cli logs "${query}"
    [ "${status}" -eq 2 ] || return 1
    [[ ${stderr} == *'does not carry'* ]] || return 1
  done
}

@test 'the four guaranteed labels all pass and reach the bundle' {
  run_cli logs '{container="coder", stream="stdout", job="stack", stack="dev"}'
  [ "${status}" -eq 0 ]
  stub_said '/api/datasources/proxy/uid/loki/loki/api/v1/query_range'
  assert_out 'summary: 1 ok, 0 warnings, 0 failed'
}

@test 'a non-ASCII query is refused as the quoting mistake it is' {
  local accent
  accent="$(printf '\303\251')" # one UTF-8 e-acute, built so this file stays ASCII
  run_cli logs "{container=\"caf${accent}\"}"
  [ "${status}" -eq 2 ]
  assert_err 'printable ASCII'
}

@test 'the profile being off is a note and a clean exit for every verb' {
  export OBSERVABILITY_ENABLED=false
  local verb
  for verb in 'logs {container="coder"}' 'metrics up' alerts dashboards 'search spark'; do
    # shellcheck disable=SC2086
    run_cli ${verb}
    [ "${status}" -eq 0 ] || return 1
    [[ ${output} == *'profile off'* ]] || return 1
    [[ ${output} == *'summary: 0 ok, 0 warnings, 0 failed'* ]] || return 1
  done
  run_cli --self-test
  [ "${status}" -eq 0 ]
  assert_out 'profile off'
  # A box that never enabled the bundle must not be probed at all.
  [ ! -f "${STUB_LOG}/curl.log" ]
  [ ! -f "${STUB_LOG}/docker.log" ]
}

@test 'an endpoint that cannot be reached is an error, never an all-clear' {
  plan_for '*' 7 000 ''
  run_cli dashboards
  [ "${status}" -eq 1 ]
  assert_err 'error:'
  assert_err 'reached nothing at http://127.0.0.1:3005/api/search'
  # The phrase that lets an agent stop looking belongs to a real answer only.
  refute_out 'nothing here is broken'
  refute_err 'nothing here is broken'
  refute_out 'profile off'
  refute_err 'profile off'
  assert_out 'summary: 0 ok, 0 warnings, 1 failed'
}

@test 'the base URL comes from --base-url, then GRAFANA_URL, then GRAFANA_BASE_URL' {
  plan_for 'api/search' 0 200 '[{"title":"x","type":"dash","uid":"x"}]'
  run_cli dashboards
  stub_said 'http://127.0.0.1:3005/api/search?type=dash-db'

  export GRAFANA_URL='https://grafana.example.test'
  run_cli dashboards
  stub_said 'https://grafana.example.test/api/search?type=dash-db'

  unset GRAFANA_URL
  export GRAFANA_BASE_URL='http://host.docker.internal:3005'
  run_cli dashboards
  stub_said 'http://host.docker.internal:3005/api/search?type=dash-db'

  run_cli dashboards --base-url 'http://127.0.0.1:3999/'
  stub_said 'http://127.0.0.1:3999/api/search?type=dash-db'
}

@test 'a base URL from the dotenv is honoured, and its source is named' {
  plan_for 'api/search' 0 200 '[{"title":"x","type":"dash","uid":"x"}]'
  printf '%s\n' 'GRAFANA_URL=http://grafana.lan:3005' >>"${PROJ}/.env"
  run_cli dashboards
  [ "${status}" -eq 0 ]
  stub_said 'http://grafana.lan:3005/api/search?type=dash-db'

  : >"${PLAN_LIST}"
  plan_for '*' 7 000 ''
  run_cli dashboards
  [ "${status}" -eq 1 ]
  assert_err 'GRAFANA_URL'
}

@test 'a base URL that is not an origin is refused before the first request' {
  for bad in 'http://grafana.test/api' 'ftp://grafana.test' 'grafana.test' \
    'http://user:pw@grafana.test' 'https://grafana.test?x=1' ''; do
    run_cli dashboards --base-url "${bad}"
    [ "${status}" -eq 2 ] || {
      printf 'accepted %s\n' "${bad}" >&2
      return 1
    }
    assert_err 'not one this CLI can dial'
  done
  [ ! -f "${STUB_LOG}/curl.log" ]
}

@test 'logs prints the payload and counts the streams it got back' {
  plan_for 'query_range' 0 200 \
    '{"data":{"result":[{"stream":{"container":"coder"},"values":[["1","a"]]},{"stream":{"job":"stack"},"values":[["2","b"]]}]}}'
  run_cli logs '{container="coder"}'
  [ "${status}" -eq 0 ]
  assert_out '"stream":{"container":"coder"}'
  assert_out 'ok: logs: 2 streams'
  assert_summary_last_line
}

@test 'an empty range is no data, which is an answer and not a broken bundle' {
  plan_for 'query_range' 0 200 '{"data":{"result":[]}}'
  run_cli logs '{container="coder"}'
  [ "${status}" -eq 0 ]
  assert_out 'no data:'
  # The all-clear is earned only where the bundle actually answered and matched
  # nothing, which is this state and no other.
  assert_out 'nothing here is broken'
  refute_out 'error:'
  refute_err 'error:'
  assert_out 'summary: 0 ok, 0 warnings, 0 failed'
}

@test 'metrics goes to prometheus and long windows go to mimir' {
  run_cli metrics 'rate(litellm_requests_total[5m])'
  [ "${status}" -eq 0 ]
  stub_said '/api/datasources/proxy/uid/prometheus/api/v1/query_range'
  stub_said 'rate%28litellm_requests_total%5B5m%5D%29'

  run_cli metrics 'up' --source mimir --since 7d
  [ "${status}" -eq 0 ]
  stub_said '/api/datasources/proxy/uid/mimir/api/v1/query_range'
  assert_out 'source mimir, last 7d'
}

@test 'the lib keeps PromQL on the datasources that serve it' {
  run --separate-stderr bash -c "source '${LIB}'; obsq_query_path tempo >/dev/null && obsq_query_path loki"
  [ "${status}" -eq 0 ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_datasource tempo | grep -q 'tempo.*tempo'"
  [ "${status}" -eq 0 ]
  # The CLI's own guard: a non-PromQL datasource named by --source never reaches HTTP.
  run_cli metrics 'up' --source mimir
  [ "${status}" -eq 0 ]
  stub_said '/uid/mimir/'
}

@test 'alerts reaches Alertmanager from inside the project network' {
  run_cli alerts
  [ "${status}" -eq 0 ]
  assert_out 'summary: 1 ok, 0 warnings, 0 failed'
  assert_out '"alertname":"DiskFull"'
  stub_said '--network stackproj_default' docker.log
  stub_said 'curlimages/curl:8.10.1' docker.log
  stub_said 'http://alertmanager:9093/api/v2/alerts' docker.log
  # Alertmanager needs no credential, so none may travel with the request.
  [ ! -f "${STUB_LOG}/curl.log" ]
}

@test 'alerts with --no-docker uses the host loopback instead of a container' {
  run_cli alerts --no-docker
  [ "${status}" -eq 0 ]
  stub_said 'http://127.0.0.1:9093/api/v2/alerts'
  [ ! -f "${STUB_LOG}/docker.log" ]
}

@test 'a missing daemon for alerts is an error that names the transport' {
  export DOCKER_UNAVAILABLE=1
  run_cli alerts
  [ "${status}" -eq 1 ]
  assert_err 'error:'
  assert_err 'http://alertmanager:9093/api/v2/alerts'
  refute_out 'profile off'
  refute_err 'profile off'
}

@test 'dashboards and search both go through the Grafana search API' {
  plan_for 'api/search' 0 200 '[{"title":"Spark","uid":"spark","type":"dash","url":"/d/spark"}]'
  run_cli dashboards
  [ "${status}" -eq 0 ]
  stub_said 'api/search?type=dash-db'
  assert_out 'ok: dashboards: 1 dashboards'

  run_cli search spark
  [ "${status}" -eq 0 ]
  stub_said 'api/search?query=spark'
}

@test 'a refused credential is an error that names the file and never the value' {
  plan_for '*' 0 401 "{\"message\":\"Unauthorized: the presented value ${STUB_CRED} is invalid\"}"
  run_cli logs '{container="coder"}'
  [ "${status}" -eq 1 ]
  assert_err "${GRAFANA_QUERY_TOKEN_FILE}"
  assert_err 'read-only service-account token'
  refute_out "${STUB_CRED}"
  assert_out 'summary: 0 ok, 0 warnings, 1 failed'
}

@test 'a 500 from a datasource is an error that names the provisioning file' {
  plan_for '*' 0 500 'upstream connect error'
  run_cli metrics 'up'
  [ "${status}" -eq 1 ]
  assert_err 'answered 500'
  refute_out 'profile off'
}

@test 'the credential appears nowhere in what the run prints or the stubs record' {
  # The nastiest shape: the bundle echoes the credential back inside the payload,
  # and curl's own complaint mentions it too.
  plan_for '*' 0 200 \
    "{\"data\":{\"result\":[{\"stream\":{\"container\":\"coder\"},\"values\":[[\"1\",\"auth used ${STUB_CRED} here\"]]}]}}"
  export CURL_ERR="the server echoed ${STUB_CRED}"
  run_cli logs '{container="coder"}'
  [ "${status}" -eq 0 ]
  assert_out '[redacted]'
  refute_out "${STUB_CRED}"
  refute_err "${STUB_CRED}"
  local log
  for log in "${STUB_LOG}"/*; do
    if grep -qF -- "${STUB_CRED}" "${log}"; then
      return 1
    fi
  done
  # And it never joined argv, which is where the stub log would have caught it.
  stub_said '--config'
}

@test 'a missing credential is an error, distinct from the profile being off' {
  rm -f "${TOKEN}"
  run_cli logs '{container="coder"}'
  [ "${status}" -eq 1 ]
  assert_err 'no usable service-account token'
  assert_err "${GRAFANA_QUERY_TOKEN_FILE}"
  refute_out 'profile off'
  [ ! -f "${STUB_LOG}/curl.log" ]
}

@test 'an unreadable token file is called out as its own failure' {
  chmod 000 "${TOKEN}"
  run_cli dashboards
  [ "${status}" -eq 1 ]
  assert_err 'cannot be read'
  chmod 600 "${TOKEN}"
}

@test 'a value that is not one token is refused rather than sent' {
  write_token_file "${TOKEN}" "bad value with spaces"
  run_cli dashboards
  [ "${status}" -eq 1 ]
  assert_err 'no usable service-account token'
  [ ! -f "${STUB_LOG}/curl.log" ]
}

@test 'self-test proves the credential and every provisioned datasource, data-free' {
  plan_for 'labels' 0 200 '{"data":["container","job","stack"]}'
  plan_for 'api/search' 0 200 '[{"title":"x","type":"dash"}]'
  run_cli --self-test
  [ "${status}" -eq 0 ]
  assert_out 'authenticates against Grafana'
  local uid
  for uid in "${DS_UIDS[@]}"; do
    assert_out "(uid ${uid}) answers through the proxy"
    stub_said "/api/datasources/proxy/uid/${uid}/"
  done
  # It proves the bundle answers; it is not a way to pull data out of it.
  refute_out '"data":'
  assert_summary_last_line
}

@test 'self-test fails and says which datasource did not answer' {
  plan_for 'api/search' 0 200 '[{"title":"x","type":"dash"}]'
  plan_for '/uid/tempo/' 0 503 'tempo is down'
  run_cli --self-test
  [ "${status}" -eq 1 ]
  assert_err 'the tempo datasource (uid tempo) did not answer'
  assert_err 'provisioning/datasources/stack.yaml'
  assert_out 'summary: 4 ok, 0 warnings, 1 failed'
}

@test 'self-test with a dead credential stops instead of blaming every datasource' {
  plan_for 'api/search' 0 403 'Permission denied'
  run_cli --self-test
  [ "${status}" -eq 1 ]
  assert_err 'does not authenticate'
  assert_err "${GRAFANA_QUERY_TOKEN_FILE}"
  refute_out 'datasources/proxy/uid/prometheus'
}

@test 'the summary line is always the last line of the report' {
  run_cli dashboards
  assert_summary_last_line
  plan_for '*' 0 500 'boom'
  run_cli metrics 'up'
  assert_summary_last_line
}

@test '--json leaves stdout as the payload alone and moves the report away' {
  plan_for '*' 0 200 '[{"title":"Spark","uid":"spark","type":"dash"}]'
  run_cli dashboards --json
  [ "${status}" -eq 0 ]
  assert_out_exact '[{"title":"Spark","uid":"spark","type":"dash"}]'
  refute_out 'summary:'
  assert_err 'summary: 1 ok, 0 warnings, 0 failed'
  assert_err '== dashboards =='
}

@test 'the lib encodes a query without touching what a URL parser needs' {
  run --separate-stderr bash -c "source '${LIB}'; obsq_urlencode '{container=\"a b\"} |= \"c/d?e&f'"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = '%7Bcontainer%3D%22a%20b%22%7D%20%7C%3D%20%22c%2Fd%3Fe%26f' ]
}

@test 'the lib parses the windows this CLI accepts and no others' {
  local pair dur want
  for pair in '15s:15' '15m:900' '1h:3600' '24h:86400' '7d:604800'; do
    dur="${pair%%:*}"
    want="${pair##*:}"
    run --separate-stderr bash -c "source '${LIB}'; obsq_since_seconds '${dur}'"
    [ "${status}" -eq 0 ] || return 1
    [ "${lines[0]}" = "${want}" ] || return 1
  done
  for dur in '7' '1w' '-5m' '1h30m' '1.5h'; do
    run --separate-stderr bash -c "source '${LIB}'; obsq_since_seconds '${dur}'"
    [ "${status}" -ne 0 ] || return 1
  done
}

@test 'the lib separates the four answer shapes the CLI promises apart' {
  run --separate-stderr bash -c "source '${LIB}'; obsq_answer_shape 7 '000' ''"
  [ "${lines[0]}" = 'error' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_answer_shape 1 '000' ''"
  [ "${lines[0]}" = 'error' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_answer_shape 0 '' ''"
  [ "${lines[0]}" = 'error' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_answer_shape 0 '401' 'no'"
  [ "${lines[0]}" = 'error' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_answer_shape 0 '500' 'boom'"
  [ "${lines[0]}" = 'error' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_answer_shape 1 '' 'SSL wrong'"
  [ "${lines[0]}" = 'error' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_answer_shape 0 '200' '{\"data\":{\"result\":[]}}'"
  [ "${lines[0]}" = 'nodata' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_answer_shape 0 '200' '[]'"
  [ "${lines[0]}" = 'nodata' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_answer_shape 0 '200' '[{\"labels\":{}}]'"
  [ "${lines[0]}" = 'data' ]
}

@test 'the lib separates an unreachable endpoint from every other failure' {
  run --separate-stderr bash -c "source '${LIB}'; obsq_is_refused 7 'Connection refused'"
  [ "${status}" -eq 0 ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_is_refused 1 'Cannot connect to the Docker daemon'"
  [ "${status}" -eq 0 ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_is_refused 1 'SSL wrong'"
  [ "${status}" -eq 1 ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_is_refused 0 'nonsense'"
  [ "${status}" -eq 1 ]
}

@test 'the lib accepts an origin and refuses everything that is not one' {
  local pair
  for pair in 'http://127.0.0.1:3005|http://127.0.0.1:3005' \
    'https://grafana.example.test|https://grafana.example.test' \
    'http://host.docker.internal:3005/|http://host.docker.internal:3005' \
    'http://a//|http://a' 'https://[::1]:3005|https://[::1]:3005'; do
    run --separate-stderr bash -c "source '${LIB}'; obsq_validate_base_url '${pair%%|*}'"
    [ "${status}" -eq 0 ] || {
      printf 'refused %s\n' "${pair%%|*}" >&2
      return 1
    }
    [ "${lines[0]}" = "${pair##*|}" ] || return 1
  done
  for bad in '' 'grafana.test' 'http://' 'http://h/p' 'http://h?q=1' 'http://u@h' \
    'http://h x' 'ftp://h' 'HTTP://h'; do
    run --separate-stderr bash -c "source '${LIB}'; obsq_validate_base_url '${bad}'"
    [ "${status}" -eq 1 ] || {
      printf 'accepted %s\n' "${bad}" >&2
      return 1
    }
  done
}

@test 'the lib counts each payload shape by the field every row must carry' {
  run --separate-stderr bash -c "source '${LIB}'; obsq_result_count streams '{\"data\":{\"result\":[{\"stream\":{\"a\":\"b\"}},{\"stream\":{\"c\":\"d\"}}]}}'"
  [ "${lines[0]}" = '2' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_result_count series '{\"data\":{\"result\":[{\"metric\":{}}]}}'"
  [ "${lines[0]}" = '1' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_result_count alerts '[]'"
  [ "${lines[0]}" = '0' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_result_count nonsense 'anything'"
  [ "${lines[0]}" = '0' ]
}

@test 'the lib is the only place the guaranteed label set is written down' {
  run --separate-stderr bash -c "source '${LIB}'; obsq_allowed_labels | tr '\n' ' '"
  [ "${lines[0]}" = 'container stream job stack ' ]
  # The CLI must not keep a second copy of the set to drift.
  if grep -q 'OBSQ_ALLOWED_LABELS' "${SCRIPT}"; then
    return 1
  fi
  grep -q 'obsq_allowed_labels' "${SCRIPT}"
}

@test 'the lib refuses a token file it cannot trust' {
  local missing="${SCRATCH}/nope"
  run --separate-stderr bash -c "source '${LIB}'; obsq_read_token '${missing}'"
  [ "${status}" -eq 1 ]

  local blank="${SCRATCH}/blank"
  : >"${blank}"
  run --separate-stderr bash -c "source '${LIB}'; obsq_read_token '${blank}'"
  [ "${status}" -eq 1 ]

  local quote="${SCRATCH}/quote"
  (
    umask 077
    printf 'a quote and a percent into the value\n' >"${quote}"
  )
  run --separate-stderr bash -c "source '${LIB}'; obsq_read_token '${quote}'"
  [ "${status}" -eq 1 ]

  local good="${SCRATCH}/good"
  write_token_file "${good}" "  ${STUB_CRED}  "
  run --separate-stderr bash -c "source '${LIB}'; obsq_read_token '${good}'"
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "${STUB_CRED}" ]
}

@test 'the lib resolves only the datasources the bundle provisions' {
  local uid
  for uid in "${DS_UIDS[@]}"; do
    run --separate-stderr bash -c "source '${LIB}'; obsq_datasource '${uid}'"
    [ "${status}" -eq 0 ] || return 1
  done
  run --separate-stderr bash -c "source '${LIB}'; obsq_datasource 'jaeger'"
  [ "${status}" -eq 1 ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_query_path 'loki'"
  [ "${lines[0]}" = '/loki/api/v1/query_range' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_labels_path 'loki'"
  [ "${lines[0]}" = '/loki/api/v1/labels' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_query_path 'jaeger'"
  [ "${status}" -eq 1 ]
}

@test 'the lib redacts a value that carries glob characters' {
  run --separate-stderr bash -c "source '${LIB}'; GRAFANA_TOKEN='a*b.c[d]' obsq_redact 'leak a*b.c[d] end'"
  [ "${lines[0]}" = 'leak [redacted] end' ]
  run --separate-stderr bash -c "source '${LIB}'; obsq_redact 'nothing to hide'"
  [ "${lines[0]}" = 'nothing to hide' ]
}

@test 'the lib reads the datasource UIDs the provisioning file actually ships' {
  local prov="${REPO_ROOT}/observability/grafana/provisioning/datasources/stack.yaml"
  [ -f "${prov}" ] || skip "the datasource provisioning file is not in the tree"
  local uid
  for uid in "${DS_UIDS[@]}"; do
    if ! grep -Eq "^[[:space:]]*uid:[[:space:]]*${uid}[[:space:]]*$" "${prov}"; then
      fail "provisioning names no ${uid} datasource, so scripts/lib/observability_query.sh is stale"
    fi
  done
}

@test 'every helper the CLI and its lib declare is named by this suite' {
  local helper found
  for helper in "${CLI_HELPERS[@]}" "${LIB_HELPERS[@]}"; do
    found=0
    grep -Eq "^[[:space:]]*${helper}\(\)" "${SCRIPT}" "${LIB}" && found=1
    [ "${found}" -eq 1 ] || fail "${helper} is declared by neither the CLI nor its lib"
    if ! grep -qF -- "${helper}" "${BATS_TEST_FILENAME}"; then
      fail "${helper} is never named under tests/, so shell_inventory would fail"
    fi
  done
}
