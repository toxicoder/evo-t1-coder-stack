#!/usr/bin/env bash
#
# ## observability-query.sh - ask the observability bundle a question.
#
# The bundle's data is behind two walls a coding agent has no way through on its
# own: Loki, Mimir and Tempo publish no host port at all, and Grafana, the one
# thing that is published, answers only to a credential. This CLI is the door:
# five verbs, one read-only service-account token read from a file, and one
# answer shape a machine can branch on.
#
# Every query goes to a provisioned datasource by UID through Grafana's datasource
# proxy (/api/datasources/proxy/uid/<uid>/...), so the token is the only
# credential this needs and the query language is the one the panel already uses.
# The two backends that need no credential and bind loopback only - Alertmanager
# on 127.0.0.1:9093 - are reached the way scripts/observability-check.sh:454
# reaches everything it cannot publish: a one-shot curlimages/curl container on
# the project network, which is also the only way a workspace container reaches
# the stack host's loopback. --no-docker switches that verb to the host's own
# loopback, for a run on the stack host itself.
#
# The credential is a read-only Grafana service-account token minted into a file
# on a named volume. It is read from that file and nowhere else: never argv (so
# never a process listing, a shell history line, or a test stub's argv log), never
# printed, and scrubbed out of every string this prints, including the response
# body, which is the one place a token can come back unasked for. It reaches curl
# through --config, not -H, for the same reason.
#
# Three states are answered apart, because collapsing them is how a working bundle
# gets declared broken: the profile is off (the normal look of a box that never
# enabled it, so exit 0 and a note), the bundle is up and holds nothing for that
# query (exit 0 and a note), and something is actually wrong (exit 1 and an error).
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:observability-query -- logs '{container="coder"} |~ "error"'
#   bazelisk run //scripts:observability-query -- metrics 'rate(litellm_requests_total[5m])'
#   bazelisk run //scripts:observability-query -- metrics 'up' --source mimir --since 7d
#   bazelisk run //scripts:observability-query -- alerts
#   bazelisk run //scripts:observability-query -- dashboards
#   bazelisk run //scripts:observability-query -- search spark
#   bazelisk run //scripts:observability-query -- --self-test
#
# Options (accepted anywhere in argv):
#   --env-file PATH     dotenv the ports are read from. Default: $ENV_FILE, else
#                       ./.env beside $COMPOSE_FILE, else ./.env
#   --token-file PATH   the service-account token file. Default: $GRAFANA_QUERY_TOKEN_FILE,
#                       else /var/lib/evo-t1-observability/grafana-query-token
#   --since DUR         window for logs and metrics. Default 1h. Whole number with
#                       s, m, h or d
#   --step DUR          metrics range step. Default: none, one point per series
#   --limit N           rows asked for. Default 50, max 500
#   --source NAME       metrics datasource: prometheus or mimir. Default prometheus;
#                       use mimir for windows past Prometheus' retention
#   --timeout SECS      per-request curl budget. Default 5.
#   --no-docker         reach the unpublished backends over the host's loopback
#                       instead of a one-shot container on the project network
#   --json              payload only on stdout; the report goes to stderr
#   -h | --help         print usage, exit 0
#
# Log filtering is restricted to the labels Loki is guaranteed to carry -
# container, stream, job, stack - and a selector that names any other label is
# refused before the first request, because a label Loki never shipped returns an
# empty result and looks exactly like an empty box.
#
# Output: the house vocabulary - "== section ==", "-> phase", "ok:", "warning:",
#   "note:", "error:", and a closing "summary: N ok, W warnings, F failed" as the
#   last line of the run. With --json every one of those lines goes to stderr and
#   stdout carries only the payload.
# Exit codes: 0 on data, on no data, and on the profile being off; 1 when a query
#   or the credential actually failed; 2 on a usage error, always answered before
#   the first request, including a label outside the allowed set.
#
# Related: scripts/observability-check.sh (proves the bundle is wired; this one
#   asks it questions), scripts/lib/observability_query.sh (the label rule, the
#   token, the answer shapes), docs/dashboard.md (the panels these verbs mirror).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# @function obsq_resolve_root
# Print the checkout this run reads its libs from: the first candidate holding a
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
obsq_resolve_root() {
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

# @function obsq_find_lib
# Print the path one sourced lib is reachable from: the resolved root first, then
# this script's own directory. Under `bazelisk run //scripts:observability-query`
# both exist inside the runfiles copy, which //scripts:doc_sources makes true.
# Globals:
#   SELF_DIR
# Arguments:
#   $1 - lib file name, relative to the lib directory; $2 - resolved repo root,
#   possibly empty
# Outputs:
#   The lib path on stdout, or one complaint line on stderr
# Returns:
#   0 when the lib was found, 1 otherwise
obsq_find_lib() {
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

REPO_ROOT_RESOLVED="$(obsq_resolve_root || true)"
COMMON_LIB="$(obsq_find_lib common.sh "${REPO_ROOT_RESOLVED}")" || {
  printf 'error: observability-query cannot run without its helpers: no scripts/lib/common.sh above\n' >&2
  exit 1
}
QUERY_LIB="$(obsq_find_lib observability_query.sh "${REPO_ROOT_RESOLVED}")" || {
  printf 'error: observability-query cannot run without its helpers: no scripts/lib/observability_query.sh above\n' >&2
  exit 1
}

# shellcheck source=lib/common.sh disable=SC1091
source "${COMMON_LIB}"
# shellcheck source=lib/observability_query.sh disable=SC1091
source "${QUERY_LIB}"

# The default is the human report on stdout. --json flips it back on after argv,
# which sends every prose line to stderr and leaves the payload alone on stdout,
# the channel an agent parses.
unset JSON_MODE

# -- knobs -----------------------------------------------------------------

# Where the boot step that mints the read-only service-account token leaves it, on
# the named volume the workspace mounts. A path, not a value: the token itself is
# never taken from argv or the environment.
GRAFANA_QUERY_TOKEN_FILE="${GRAFANA_QUERY_TOKEN_FILE:-/var/lib/evo-t1-observability/grafana-query-token}"

# The only place the token ever lives in this process. It is read once, handed to
# curl through a config file and never interpolated into a report line unscrubbed.
GRAFANA_TOKEN=""

ENV_FILE_ARG=""
TOKEN_FILE_ARG=""
TIMEOUT=5
LIMIT=50
SINCE="1h"
STEP=""
SOURCE="prometheus"
NO_DOCKER=0
SELF_TEST=0
VERB=""
QUERY=""
TERM=""
COMPOSE_FILE="${COMPOSE_FILE:-}"
ENV_SRC=""
PROJECT_NAME=""
WORK_DIR=""

# The transport answers, filled by obsq_fetch and obsq_fetch_in_network and read
# by the caller that asks about their shape.
FETCH_RC=0
FETCH_CODE=""
FETCH_ERR=""

# @function usage
# Print the verb list, the flag list and the exit-code contract on stdout.
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
Usage: bazelisk run //scripts:observability-query -- VERB [ARGS] [OPTIONS]

Verbs:
  logs QUERY          LogQL over the provisioned loki datasource. QUERY may
                      filter only on container, stream, job or stack
  metrics QUERY       PromQL over the provisioned prometheus datasource;
                      --source mimir for windows past Prometheus retention
  alerts              Alertmanager's /api/v2/alerts, from inside the project
                      network (or the host loopback with --no-docker)
  dashboards          Grafana's /api/search?type=dash-db: what is registered
  search TERM         Grafana's /api/search?query=TERM: dashboards, folders,
                      panels and datasources that match
  --self-test         prove the token and every provisioned datasource answer,
                      without returning any data

Options:
  --env-file PATH     dotenv the ports are read from. Default: $ENV_FILE, else
                      ./.env beside $COMPOSE_FILE, else ./.env
  --token-file PATH   the service-account token file. Default:
                      $GRAFANA_QUERY_TOKEN_FILE, else
                      /var/lib/evo-t1-observability/grafana-query-token
  --since DUR         window for logs and metrics. Default 1h (s, m, h, d)
  --step DUR          metrics range step. Default: none
  --limit N           rows asked for. Default 50, max 500
  --source NAME       metrics datasource: prometheus or mimir. Default prometheus
  --timeout SECS      per-request curl budget. Default 5.
  --no-docker         reach unpublished backends over the host loopback instead
                      of a one-shot curlimages/curl container
  --json              payload only on stdout; the report goes to stderr
  -h | --help         print this, exit 0

The token is read from a file and never from argv, is never printed, and is
scrubbed out of anything the bundle echoes back. Three states are answered
apart: the observability compose profile being off, a bundle that is up and
holds nothing for this query, and a real failure.

Exit codes: 0 on data, on no data and on the profile being off; 1 when a query
or the credential failed; 2 on a usage error, including a log label outside
container, stream, job, stack.
USAGE
}

# @function usage_error
# Print one usage complaint plus the usage block on stderr, and exit 2, so a typo
# or an invented label is never mistaken for a result. Everything on stderr: a
# caller that pipes the happy path's payload somewhere sees only the payload.
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

# @function obsq_key
# Print one compose key this CLI needs, in compose's own precedence: the process
# environment first, then the dotenv file, then the shipped default. The ports and
# nothing else are read this way; the token is never looked for here.
# Globals:
#   ENV_SRC
# Arguments:
#   $1 - key name; $2 - the default when the key is absent or blank
# Outputs:
#   The value on stdout, with no trailing newline
# Returns:
#   0, always
obsq_key() {
  local key="$1" default="${2:-}" value=""
  value="${!key:-}"
  if [ -z "${value}" ] && [ -f "${ENV_SRC}" ]; then
    value="$(env_get "${ENV_SRC}" "${key}")"
  fi
  if [ -z "${value}" ]; then
    value="${default}"
  fi
  printf '%s' "${value}"
  return 0
}

# @function profile_switched_off
# Succeed when the observability compose profile is switched off, which is the
# answer that has to be reached before any request is made: the whole bundle rides
# profiles: ["observability"], so on a box that never enabled it there is nothing
# to query and nothing is broken. The decision is not re-derived here - it is
# compose_observability_args', the one seam that owns it.
# Globals:
#   ENV_SRC
# Arguments:
#   None
# Outputs:
#   None
# Returns:
#   0 when the profile is off, 1 when it is on
profile_switched_off() {
  local prof=""
  prof="$(compose_observability_args "${ENV_SRC}")"
  [ -z "${prof}" ]
}

# @function obsq_report_profile_off
# Print the one note that answers "this box never started the bundle", used for
# both ways that shows up: the key that decides the profile says off, and the
# transport answering nothing because nothing is listening. Neither is a fault, so
# neither is allowed to fail the run.
# Globals:
#   ENV_SRC
# Arguments:
#   $1 - the verb, for the line a caller greps
# Outputs:
#   One note: line
# Returns:
#   0, always
obsq_report_profile_off() {
  local what="${1:-query}"
  note "${what}: profile off - the whole observability bundle rides the observability compose profile, so its services were never started on this box and there is nothing to query. Nothing here is broken: set OBSERVABILITY_ENABLED=true in ${ENV_SRC} and bring it up with //scripts:dev-stack -- up"
  return 0
}

# @function obsq_require_token
# Read the service-account token into GRAFANA_TOKEN the first time a verb needs it.
# A missing token is an error and not the off state: the profile check already
# answered "never enabled", so a box that is enabled and has no credential has a
# boot step that did not run, which is exactly what the operator needs told.
# Globals:
#   GRAFANA_TOKEN, GRAFANA_QUERY_TOKEN_FILE
# Arguments:
#   None
# Outputs:
#   One error: line when the token is unusable
# Returns:
#   0 with the token in hand, 1 without it
obsq_require_token() {
  if [ -n "${GRAFANA_TOKEN}" ]; then
    return 0
  fi
  local token="" rc=0
  token="$(obsq_read_token "${GRAFANA_QUERY_TOKEN_FILE}")" || rc=$?
  case "${rc}" in
    0)
      GRAFANA_TOKEN="${token}"
      return 0
      ;;
    2)
      fail_item "the service-account token file ${GRAFANA_QUERY_TOKEN_FILE} cannot be read: check its owner and mode, the minting step writes it readable by the agent user only"
      ;;
    *)
      fail_item "no usable service-account token in ${GRAFANA_QUERY_TOKEN_FILE}: the boot step that mints the read-only Grafana token has not run, or wrote a value that is not one token (a token is one line of letters, digits, dot, dash, underscore and tilde)"
      ;;
  esac
  return 1
}

# @function obsq_fetch
# Run one curl against a published loopback port and keep the three things the
# answer shape needs: the transport status, the HTTP status code, and the body in
# a file. No -f, because a 404, a 401 and a refused socket are three different
# findings here and -f would fold them into one non-zero exit. The credential
# travels in a curl config file rather than a -H argument, so it never joins argv.
# Globals:
#   TIMEOUT, WORK_DIR, GRAFANA_TOKEN, FETCH_RC, FETCH_CODE, FETCH_ERR
# Arguments:
#   $1 - the URL; $2 - file to write the body to; $3 - auth or none
# Outputs:
#   The body in $2
# Returns:
#   0, always: the caller asks obsq_answer_shape what to make of it
obsq_fetch() {
  local url="$1" body_file="$2" auth="${3:-auth}" rc=0
  FETCH_RC=0
  FETCH_CODE=""
  FETCH_ERR=""
  local -a creds=()
  if [ "${auth}" = "auth" ]; then
    (
      umask 077
      printf 'header = "Authorization: Bearer %s"\n' "${GRAFANA_TOKEN}" >"${WORK_DIR}/curlrc"
    )
    creds=(--config "${WORK_DIR}/curlrc")
  fi
  capped_run "${TIMEOUT}" curl -sS --max-time "${TIMEOUT}" "${creds[@]}" \
    -o "${body_file}" -w '%{http_code}' "${url}" >"${WORK_DIR}/code" 2>"${WORK_DIR}/err" || rc=$?
  FETCH_RC="${rc}"
  FETCH_CODE="$(sed -n '1p' "${WORK_DIR}/code" 2>/dev/null || true)"
  FETCH_ERR="$(sed -n '1p' "${WORK_DIR}/err" 2>/dev/null || true)"
  return 0
}

# @function obsq_fetch_in_network
# Run one request from inside the compose project network with a pinned one-shot
# curl image, the way scripts/observability-check.sh:454 reaches every backend that
# publishes no host port. Alertmanager binds 127.0.0.1 on the stack host only, so
# from a workspace container this is the only way to ask it anything at all. curl
# in the container writes the body to stdout and the status code after a newline,
# which is how the body and the code are split back apart here.
# Globals:
#   TIMEOUT, WORK_DIR, PROJECT_NAME, OBSQ_CURL_IMAGE, FETCH_RC, FETCH_CODE, FETCH_ERR
# Arguments:
#   $1 - the URL; $2 - file to write the body to
# Outputs:
#   The body in $2
# Returns:
#   0, always
obsq_fetch_in_network() {
  local url="$1" body_file="$2" rc=0 answer=""
  FETCH_RC=0
  FETCH_CODE=""
  FETCH_ERR=""
  answer="$(capped_run "${TIMEOUT}" docker run --rm --network "${PROJECT_NAME}_default" \
    "${OBSQ_CURL_IMAGE}" -sS --max-time "${TIMEOUT}" -o - -w '\n%{http_code}' "${url}" \
    2>"${WORK_DIR}/err")" || rc=$?
  FETCH_RC="${rc}"
  FETCH_ERR="$(sed -n '1p' "${WORK_DIR}/err" 2>/dev/null || true)"
  case "${answer}" in
    '') ;;
    *$'\n'*)
      FETCH_CODE="${answer##*$'\n'}"
      printf '%s' "${answer%$'\n'*}" >"${body_file}"
      ;;
    *)
      FETCH_CODE="${answer}"
      : >"${body_file}"
      ;;
  esac
  return 0
}

# @function obsq_emit
# Print a response body on stdout: the payload, which is what the caller asked for.
# It passes through the redaction like every other string, because a log line is
# free to quote the request that wrote it and a token that came back in a body is
# still a token that must not reach a transcript.
# Globals:
#   GRAFANA_TOKEN
# Arguments:
#   $1 - the body
# Outputs:
#   The scrubbed body on stdout, one trailing newline
# Returns:
#   0, always
obsq_emit() {
  printf '%s\n' "$(obsq_redact "${1:-}")"
  return 0
}

# @function obsq_read_body
# Print a fetch's response body for the shape and the payload. A file that curl
# never wrote (a refused socket never writes one) reads as the empty string.
# Globals:
#   None
# Arguments:
#   $1 - the body file
# Outputs:
#   The body on stdout
# Returns:
#   0, always
obsq_read_body() {
  local file="${1:-}"
  if [ -s "${file}" ]; then
    cat "${file}"
  fi
  return 0
}

# @function obsq_report_answer
# Turn one transport answer into the report it deserves, and print the payload when
# the caller wants it. This is where the three states are kept apart: off is a note
# and a clean exit, nodata is a note that says the bundle is up and simply holds
# nothing, and error names what to fix. The 401 and 403 lines name the token file
# rather than the token, because the file is the thing the operator can act on.
# Globals:
#   GRAFANA_TOKEN, GRAFANA_QUERY_TOKEN_FILE
# Arguments:
#   $1 - verb; $2 - URL; $3 - shape; $4 - transport status; $5 - HTTP status code;
#   $6 - transport complaint; $7 - body; $8 - row shape for the count; $9 - 1 to
#   print the payload, 0 to keep it in the file
# Outputs:
#   The payload on stdout, then one ok: or note: or error: line
# Returns:
#   0, always: an error is a result here, never an abort
obsq_report_answer() {
  local what="$1" url="$2" shape="$3" rc="$4" code="$5" err="$6" body="$7" kind="$8" emit="${9:-1}"
  case "${shape}" in
    off)
      obsq_report_profile_off "${what}"
      return 0
      ;;
    error)
      local detail=""
      case "${code}" in
        401 | 403)
          detail="${what} was refused by Grafana (${code}): the read-only service-account token in ${GRAFANA_QUERY_TOKEN_FILE} is expired, deleted, or lacks the role the query needs - re-run the minting step that writes that file"
          ;;
        '')
          detail="${what} got no HTTP answer from ${url}: ${err:-no answer} (transport exit ${rc})"
          ;;
        *)
          detail="${what} answered ${code} from ${url}: $(first_line "${body}")${err:+ / ${err}}"
          ;;
      esac
      fail_item "$(obsq_redact "${detail}")"
      return 0
      ;;
    nodata)
      if [ "${emit}" = "1" ] && [ -n "${body}" ]; then
        obsq_emit "${body}"
      fi
      note "no data: ${what} reached ${url} and got ${code} back with nothing in it, so the bundle is up and this window or filter matched no row - that is an answer, not a broken bundle"
      return 0
      ;;
    *)
      if [ "${emit}" = "1" ] && [ -n "${body}" ]; then
        obsq_emit "${body}"
      fi
      local n=""
      n="$(obsq_result_count "${kind}" "${body}")"
      ok "$(obsq_redact "${what}: ${n} ${kind} from ${url}")"
      return 0
      ;;
  esac
}

# @function run_logs
# Ask Loki, through the provisioned loki datasource, one LogQL range query. The
# selector is checked against the guaranteed label set first: a label Loki never
# shipped cannot match, and an empty result from a typo is the failure mode this
# CLI exists to avoid.
# Globals:
#   SINCE, LIMIT, WORK_DIR, GRAFANA_TOKEN
# Arguments:
#   $1 - the LogQL expression
# Outputs:
#   The section, the phase line, the payload and one report line
# Returns:
#   0, always
run_logs() {
  local query="$1"
  section "logs"
  if profile_switched_off; then
    obsq_report_profile_off "logs"
    return 0
  fi
  obsq_require_token || return 0

  local resolved="" uid="" type="" path="" base="" url="" secs="" now="" start="" enc=""
  resolved="$(obsq_datasource "loki")" || {
    fail_item "loki is not a provisioned datasource"
    return 0
  }
  uid="${resolved%%$'\t'*}"
  type="${resolved##*$'\t'}"
  path="$(obsq_query_path "${type}")"
  base="http://127.0.0.1:$(obsq_key GRAFANA_PORT 3005)"
  secs="$(obsq_since_seconds "${SINCE}")"
  now="$(date +%s)"
  start=$((now - secs))
  enc="$(obsq_urlencode "${query}")"
  url="${base}/api/datasources/proxy/uid/${uid}${path}?query=${enc}&start=${start}000000000&end=${now}000000000&limit=${LIMIT}"

  phase "$(obsq_redact "GET ${url} (query: ${query}, last ${SINCE}, limit ${LIMIT})")"
  local body="${WORK_DIR}/logs.json" content="" shape=""
  obsq_fetch "${url}" "${body}" auth
  content="$(obsq_read_body "${body}")"
  shape="$(obsq_answer_shape "${FETCH_RC}" "${FETCH_CODE}" "${FETCH_ERR}" "${content}")"
  obsq_report_answer "logs" "${url}" "${shape}" "${FETCH_RC}" "${FETCH_CODE}" \
    "${FETCH_ERR}" "${content}" "streams" 1
  return 0
}

# @function run_metrics
# Ask Prometheus, or Mimir for the windows Prometheus no longer keeps, one PromQL
# range query. The datasource is chosen by name and resolved to its provisioned
# UID, so the same query string runs against a short or a long retention window
# with nothing but --source changing.
# Globals:
#   SINCE, STEP, LIMIT, WORK_DIR, GRAFANA_TOKEN, SOURCE
# Arguments:
#   $1 - the PromQL expression
# Outputs:
#   The section, the phase line, the payload and one report line
# Returns:
#   0, always
run_metrics() {
  local query="$1"
  section "metrics"
  if profile_switched_off; then
    obsq_report_profile_off "metrics"
    return 0
  fi
  obsq_require_token || return 0

  local resolved="" uid="" type="" path="" base="" url="" secs="" now="" start="" enc="" extra=""
  resolved="$(obsq_datasource "${SOURCE}")" || {
    fail_item "${SOURCE} is not a provisioned datasource: metrics answers from prometheus, or from mimir for windows past Prometheus' retention"
    return 0
  }
  uid="${resolved%%$'\t'*}"
  type="${resolved##*$'\t'}"
  if [[ ${type} != "prometheus" ]]; then
    fail_item "${SOURCE} is a ${type} datasource and serves no PromQL: metrics answers from prometheus, or from mimir"
    return 0
  fi
  path="$(obsq_query_path "${type}")"
  base="http://127.0.0.1:$(obsq_key GRAFANA_PORT 3005)"
  secs="$(obsq_since_seconds "${SINCE}")"
  now="$(date +%s)"
  start=$((now - secs))
  enc="$(obsq_urlencode "${query}")"
  extra=""
  if [ -n "${STEP}" ]; then
    extra="&step=$(obsq_since_seconds "${STEP}")"
  fi
  url="${base}/api/datasources/proxy/uid/${uid}${path}?query=${enc}&start=${start}&end=${now}&limit=${LIMIT}${extra}"

  phase "$(obsq_redact "GET ${url} (query: ${query}, source ${SOURCE}, last ${SINCE}${STEP:+, step ${STEP}}, limit ${LIMIT})")"
  local body="${WORK_DIR}/metrics.json" content="" shape=""
  obsq_fetch "${url}" "${body}" auth
  content="$(obsq_read_body "${body}")"
  shape="$(obsq_answer_shape "${FETCH_RC}" "${FETCH_CODE}" "${FETCH_ERR}" "${content}")"
  obsq_report_answer "metrics" "${url}" "${shape}" "${FETCH_RC}" "${FETCH_CODE}" \
    "${FETCH_ERR}" "${content}" "series" 1
  return 0
}

# @function run_alerts
# Ask Alertmanager what it is holding. Alertmanager needs no credential and binds
# loopback on the stack host only, so the default transport is the one-shot curl
# container on the project network (scripts/observability-check.sh:454), which is
# also the only transport that works from a workspace container; --no-docker is the
# host-shell path.
# Globals:
#   NO_DOCKER, PROJECT_NAME, WORK_DIR
# Arguments:
#   None
# Outputs:
#   The section, the phase line, the payload and one report line
# Returns:
#   0, always
run_alerts() {
  section "alerts"
  if profile_switched_off; then
    obsq_report_profile_off "alerts"
    return 0
  fi
  local port="" url="" body="${WORK_DIR}/alerts.json" content="" shape=""
  port="$(obsq_key OBS_ALERTMANAGER_PORT 9093)"
  if [ "${NO_DOCKER}" = "1" ]; then
    url="http://127.0.0.1:${port}/api/v2/alerts"
    phase "GET ${url} (host loopback)"
    obsq_fetch "${url}" "${body}" none
  else
    url="http://alertmanager:${port}/api/v2/alerts"
    phase "docker run --network ${PROJECT_NAME}_default ${OBSQ_CURL_IMAGE} ${url}"
    obsq_fetch_in_network "${url}" "${body}"
  fi
  content="$(obsq_read_body "${body}")"
  shape="$(obsq_answer_shape "${FETCH_RC}" "${FETCH_CODE}" "${FETCH_ERR}" "${content}")"
  obsq_report_answer "alerts" "${url}" "${shape}" "${FETCH_RC}" "${FETCH_CODE}" \
    "${FETCH_ERR}" "${content}" "alerts" 1
  return 0
}

# @function run_dashboards
# Ask Grafana which dashboards its file provider actually registered. A JSON on
# disk is not a screen; this is the API that says whether it became one.
# Globals:
#   LIMIT, WORK_DIR, GRAFANA_TOKEN
# Arguments:
#   None
# Outputs:
#   The section, the phase line, the payload and one report line
# Returns:
#   0, always
run_dashboards() {
  section "dashboards"
  if profile_switched_off; then
    obsq_report_profile_off "dashboards"
    return 0
  fi
  obsq_require_token || return 0
  local base="" url=""
  base="http://127.0.0.1:$(obsq_key GRAFANA_PORT 3005)"
  url="${base}/api/search?type=dash-db&limit=${LIMIT}"
  phase "GET ${url}"
  local body="${WORK_DIR}/dashboards.json" content="" shape=""
  obsq_fetch "${url}" "${body}" auth
  content="$(obsq_read_body "${body}")"
  shape="$(obsq_answer_shape "${FETCH_RC}" "${FETCH_CODE}" "${FETCH_ERR}" "${content}")"
  obsq_report_answer "dashboards" "${url}" "${shape}" "${FETCH_RC}" "${FETCH_CODE}" \
    "${FETCH_ERR}" "${content}" "dashboards" 1
  return 0
}

# @function run_search
# Ask Grafana's search API for anything that matches a term: dashboards, folders,
# panels and datasources. This is how a caller finds the panel or datasource UID it
# needs before it can ask a sharper question.
# Globals:
#   LIMIT, WORK_DIR, GRAFANA_TOKEN
# Arguments:
#   $1 - the search term
# Outputs:
#   The section, the phase line, the payload and one report line
# Returns:
#   0, always
run_search() {
  local term="$1"
  section "search"
  if profile_switched_off; then
    obsq_report_profile_off "search"
    return 0
  fi
  obsq_require_token || return 0
  local base="" url=""
  base="http://127.0.0.1:$(obsq_key GRAFANA_PORT 3005)"
  url="${base}/api/search?query=$(obsq_urlencode "${term}")&limit=${LIMIT}"
  phase "$(obsq_redact "GET ${url} (term: ${term})")"
  local body="${WORK_DIR}/search.json" content="" shape=""
  obsq_fetch "${url}" "${body}" auth
  content="$(obsq_read_body "${body}")"
  shape="$(obsq_answer_shape "${FETCH_RC}" "${FETCH_CODE}" "${FETCH_ERR}" "${content}")"
  obsq_report_answer "search" "${url}" "${shape}" "${FETCH_RC}" "${FETCH_CODE}" \
    "${FETCH_ERR}" "${content}" "dashboards" 1
  return 0
}

# @function run_self_test
# Prove the credential and every provisioned datasource answer, without returning
# any data. Two questions, in the order a caller has to hear them: is the token in
# the file one Grafana still accepts, and does each datasource resolve behind the
# proxy. The datasource probe asks each one for its label names, which answers
# reachability and authorization while pulling back no sample. Nothing here prints
# a payload: an operator running this from a transcript needs the verdicts only.
# Globals:
#   WORK_DIR, GRAFANA_TOKEN, GRAFANA_QUERY_TOKEN_FILE, OBSQ_DATASOURCES
# Arguments:
#   None
# Outputs:
#   The section, one phase line per probe, and one ok:, note: or error: per probe
# Returns:
#   0, always
run_self_test() {
  section "self-test"
  if profile_switched_off; then
    obsq_report_profile_off "self-test"
    return 0
  fi
  obsq_require_token || return 0

  local base="" url="" body="${WORK_DIR}/self-token.json"
  base="http://127.0.0.1:$(obsq_key GRAFANA_PORT 3005)"
  url="${base}/api/search?limit=1"
  local content="" shape="" entry="" name="" resolved="" uid="" type="" path=""
  phase "GET ${url} (prove the token in ${GRAFANA_QUERY_TOKEN_FILE})"
  obsq_fetch "${url}" "${body}" auth
  content="$(obsq_read_body "${body}")"
  shape="$(obsq_answer_shape "${FETCH_RC}" "${FETCH_CODE}" "${FETCH_ERR}" "${content}")"
  case "${shape}" in
    off)
      obsq_report_profile_off "self-test"
      return 0
      ;;
    error)
      fail_item "the token in ${GRAFANA_QUERY_TOKEN_FILE} does not authenticate: Grafana answered ${FETCH_CODE:-nothing}${FETCH_ERR:+ / ${FETCH_ERR}} - nothing below this line can be trusted until the minting step writes a live read-only token"
      return 0
      ;;
    *)
      ok "the read-only token in ${GRAFANA_QUERY_TOKEN_FILE} authenticates against Grafana"
      ;;
  esac

  for entry in "${OBSQ_DATASOURCES[@]}"; do
    name="${entry%%:*}"
    resolved="$(obsq_datasource "${name}")" || {
      fail_item "${name} is named by this CLI and provisioned by nobody"
      continue
    }
    uid="${resolved%%$'\t'*}"
    type="${resolved##*$'\t'}"
    path="$(obsq_labels_path "${type}")"
    url="${base}/api/datasources/proxy/uid/${uid}${path}"
    body="${WORK_DIR}/self-${name}.json"
    phase "GET ${url} (prove the ${name} datasource)"
    obsq_fetch "${url}" "${body}" auth
    content="$(obsq_read_body "${body}")"
    shape="$(obsq_answer_shape "${FETCH_RC}" "${FETCH_CODE}" "${FETCH_ERR}" "${content}")"
    case "${shape}" in
      off)
        obsq_report_profile_off "self-test"
        return 0
        ;;
      error)
        fail_item "the ${name} datasource (uid ${uid}) did not answer through the Grafana proxy: ${FETCH_CODE:-nothing}${FETCH_ERR:+ / ${FETCH_ERR}} - the datasource is provisioned, so this is its backend being down or its URL in observability/grafana/provisioning/datasources/stack.yaml being wrong"
        ;;
      nodata)
        ok "${name} (uid ${uid}) answers through the proxy and holds no labels yet: the backend is reachable, the token covers it, and nothing has been written to it"
        ;;
      *)
        ok "${name} (uid ${uid}) answers through the proxy"
        ;;
    esac
  done
  return 0
}

# @function finish
# Close the run: the summary as the last line of output, and the exit code that
# answers the same question the report just answered. The off path and the no-data
# path reach here with nothing recorded as failed, so both exit 0, which is what
# lets a caller tell them apart from a failure by exit code alone.
# Globals:
#   SUMMARY_FAIL
# Arguments:
#   None
# Outputs:
#   The summary line on stdout
# Returns:
#   Nothing: exits 0 on a clean run, 1 on any failure
finish() {
  # The grammar pins the summary as the LAST line, so the recorded items are not
  # re-listed beneath it: every error was already printed where it happened.
  # shellcheck disable=SC2034 # summary() in scripts/lib/common.sh is the reader
  SUMMARY_FAIL_ITEMS=""
  summary
  if [ "${SUMMARY_FAIL:-0}" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

declare -a POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env-file)
      [ "$#" -ge 2 ] || usage_error "unknown option: $1 (--env-file needs a path)"
      ENV_FILE_ARG="$2"
      shift 2
      ;;
    --token-file)
      [ "$#" -ge 2 ] || usage_error "unknown option: $1 (--token-file needs a path)"
      TOKEN_FILE_ARG="$2"
      shift 2
      ;;
    --since)
      [ "$#" -ge 2 ] || usage_error "unknown option: $1 (--since needs a value like 15m, 1h, 24h or 7d)"
      SINCE="$2"
      shift 2
      ;;
    --step)
      [ "$#" -ge 2 ] || usage_error "unknown option: $1 (--step needs a value like 15s, 1m or 5m)"
      STEP="$2"
      shift 2
      ;;
    --limit)
      [ "$#" -ge 2 ] || usage_error "unknown option: $1 (--limit needs a whole number)"
      LIMIT="$2"
      shift 2
      ;;
    --source)
      [ "$#" -ge 2 ] || usage_error "unknown option: $1 (--source needs prometheus or mimir)"
      SOURCE="$2"
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
    --json)
      # shellcheck disable=SC2034 # log() in scripts/lib/common.sh is the reader
      JSON_MODE=1
      shift
      ;;
    --self-test)
      SELF_TEST=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage_error "unknown option: $1"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ "${SELF_TEST}" = "1" ]; then
  if [ -n "${VERB}" ] || [ "${#POSITIONAL[@]}" -gt 0 ]; then
    usage_error "--self-test proves the bundle answers and takes no verb; drop the verb and the arguments"
  fi
elif [ "${#POSITIONAL[@]}" -eq 0 ]; then
  usage_error "a verb is needed - logs, metrics, alerts, dashboards, search, or --self-test"
else
  VERB="${POSITIONAL[0]}"
  case "${VERB}" in
    logs | metrics)
      [ "${#POSITIONAL[@]}" -ge 2 ] || usage_error "${VERB} needs a query to run"
      [ "${#POSITIONAL[@]}" -le 2 ] || usage_error "${VERB} takes one query, got ${#POSITIONAL[@]} arguments"
      QUERY="${POSITIONAL[1]}"
      ;;
    alerts | dashboards)
      [ "${#POSITIONAL[@]}" -le 1 ] || usage_error "${VERB} takes no argument, got ${POSITIONAL[1]}"
      ;;
    search)
      [ "${#POSITIONAL[@]}" -ge 2 ] || usage_error "search needs a term to look for"
      [ "${#POSITIONAL[@]}" -le 2 ] || usage_error "search takes one term, got ${#POSITIONAL[@]} arguments"
      TERM="${POSITIONAL[1]}"
      ;;
    *)
      usage_error "${VERB} is not a verb - use logs, metrics, alerts, dashboards, search, or --self-test"
      ;;
  esac
fi

case "${TIMEOUT}" in '' | *[!0-9]* | 0) usage_error "unknown option: --timeout needs a whole number of seconds, got '${TIMEOUT}'" ;; esac
case "${LIMIT}" in '' | *[!0-9]* | 0) usage_error "unknown option: --limit needs a whole number above zero, got '${LIMIT}'" ;; esac
if [ "${LIMIT}" -gt 500 ]; then
  usage_error "--limit is capped at 500 rows, got ${LIMIT} - narrow the window or the filter instead"
fi
obsq_since_seconds "${SINCE}" >/dev/null ||
  usage_error "--since needs a whole number with s, m, h or d, got '${SINCE}' (try 15m, 1h, 24h, 7d)"
if [ -n "${STEP}" ]; then
  obsq_since_seconds "${STEP}" >/dev/null ||
    usage_error "--step needs a whole number with s, m, h or d, got '${STEP}' (try 15s, 1m, 5m)"
fi
if [ "${SELF_TEST}" != "1" ] && [ "${VERB}" = "metrics" ]; then
  case "${SOURCE}" in
    prometheus | mimir) ;;
    *) usage_error "--source is prometheus or mimir, got '${SOURCE}'" ;;
  esac
fi
if [ "${SELF_TEST}" != "1" ] && { [ "${VERB}" = "logs" ] || [ "${VERB}" = "metrics" ]; }; then
  obsq_assert_ascii "${QUERY}" ||
    usage_error "the query must be printable ASCII - a multibyte or control byte in it is a quoting mistake, not a filter"
fi
if [ "${SELF_TEST}" != "1" ] && [ "${VERB}" = "logs" ]; then
  BAD_LABELS=""
  if BAD_LABELS="$(obsq_logql_rejects "${QUERY}")"; then
    usage_error "the log selector filters on label(s) Loki does not carry: $(printf '%s' "${BAD_LABELS}" | tr '\n' ' ') - the guaranteed set is $(obsq_allowed_labels | tr '\n' ' ')"
  fi
  unset BAD_LABELS
fi

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
if [ -n "${TOKEN_FILE_ARG}" ]; then
  GRAFANA_QUERY_TOKEN_FILE="${TOKEN_FILE_ARG}"
fi
# The network the unpublished backends are probed on: compose names it after the
# project, and the project is named after the directory the compose file sits in.
PROJECT_NAME="$(basename "$(dirname "${COMPOSE_FILE}")")"

# One scratch directory per run for the response bodies and the curl config that
# carries the credential, removed on every exit path. mktemp -d creates it 0700,
# which is why the token file curl is handed never widens beyond this run.
WORK_DIR="$(mktemp -d 2>/dev/null || true)"
[ -n "${WORK_DIR}" ] || usage_error "could not create a scratch directory for the response bodies"
trap 'rm -rf "${WORK_DIR}"' EXIT

if [ "${SELF_TEST}" = "1" ]; then
  run_self_test
else
  case "${VERB}" in
    logs) run_logs "${QUERY}" ;;
    metrics) run_metrics "${QUERY}" ;;
    alerts) run_alerts ;;
    dashboards) run_dashboards ;;
    search) run_search "${TERM}" ;;
  esac
fi
finish
