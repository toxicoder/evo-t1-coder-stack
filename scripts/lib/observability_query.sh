#!/usr/bin/env bash
#
# ## lib/observability_query.sh - the answers observability-query.sh builds on.
#
# Sourced, never run. Everything here is a pure question: what does this LogQL
# selector filter on, is this duration one this CLI accepts, which of the four
# shapes did that HTTP answer take, does this string still carry the token. The
# report vocabulary stays in the CLI that sources this, and the compose profile
# decision stays in compose_observability_args, the one seam that owns it.
#
# Two things here are load-bearing for a caller that is a machine rather than a
# person standing at a dashboard:
#
#   the label set is not open    Loki only carries the four labels the log tag
#                               set guarantees (ctx/L0.md:64). A query that asks
#                               for a fifth is not slow, it is wrong: it returns
#                               nothing and looks like an empty box. So a label
#                               outside that set is refused before the first
#                               request rather than answered with an empty result
#
#   the token never travels      the service-account token is read from a file by
#                               obsq_read_token, kept in one variable, and every
#                               string this CLI prints passes through obsq_redact
#                               on its way out. A caller that greps the whole run
#                               for the token must find nothing
#
# Related: scripts/observability-query.sh (the CLI), scripts/observability-check.sh
#   (the bundle-side prober this shares the three-state answer with),
#   scripts/lib/common.sh (compose_observability_args, first_line, capped_run).

# The Loki labels this CLI will filter on, and the only ones it will name in a
# selector: the compose log tags, which are what Alloy ships as stream labels.
# Anything else is invented, so it is refused (see obsq_logql_rejects).
OBSQ_ALLOWED_LABELS="container stream job stack"

# The provisioned datasources as uid:type, transcribed from
# observability/grafana/provisioning/datasources/stack.yaml:15,32,46,57. The UIDs
# are what Grafana's datasource proxy addresses, so a rename in that file is a
# rename here, and the Bats suite pins the pair against the file itself.
OBSQ_DATASOURCES=(
  "prometheus:prometheus"
  "mimir:prometheus"
  "loki:loki"
  "tempo:tempo"
)

# What the token is replaced with wherever it would otherwise be echoed. One
# literal, so a test can assert on it and a human can tell a redaction from a
# value that was never secret.
OBSQ_TOKEN_REDACTION="[redacted]"

# The one-shot curl image, pinned to the same tag scripts/observability-check.sh
# uses for its in-network probes (observability-check.sh:454). Same image, same
# tag, so the two CLIs cannot disagree about what "reachable from inside the
# project network" costs.
# shellcheck disable=SC2034 # the sourcing CLI is the reader
OBSQ_CURL_IMAGE="curlimages/curl:8.10.1"

# @function obsq_allowed_labels
# Print the Loki label set this CLI filters on, one per line, in declaration
# order. It is the answer a caller gets back when a label is refused, so the
# operator does not have to open this file to learn what to write instead.
# Globals:
#   OBSQ_ALLOWED_LABELS
# Arguments:
#   None
# Outputs:
#   One label name per line on stdout
# Returns:
#   0, always
obsq_allowed_labels() {
  local label
  for label in ${OBSQ_ALLOWED_LABELS}; do
    printf '%s\n' "${label}"
  done
}

# @function obsq_assert_ascii
# Succeed when a query is printable ASCII and nothing else. The encoder below
# works a byte at a time, and the bundle's own log lines are ASCII, so a query
# carrying a multibyte or control byte is a quoting mistake at the call site
# rather than a real filter - and a newline in a query is a header injection
# waiting for the wrong transport.
# Globals:
#   None
# Arguments:
#   $1 - the query string
# Outputs:
#   None
# Returns:
#   0 when every byte is printable ASCII, 2 otherwise
obsq_assert_ascii() {
  local text="${1:-}"
  if LC_ALL=C printf '%s' "${text}" | LC_ALL=C grep -q '[^ -~]'; then
    return 2
  fi
  return 0
}

# @function obsq_logql_label_names
# Print every label name a LogQL expression mentions, one per line, unsorted and
# possibly repeated. Only a {selector} names a label: a line filter (=, !=, =~,
# !~ after the pipe) compares the line's own text, and a metric name before the
# braces is a stream selector, not a label. Entries are split on the comma, which
# is safe because a quoted value cannot carry an unquoted comma followed by a
# label name.
# Globals:
#   None
# Arguments:
#   $1 - the LogQL expression
# Outputs:
#   One label name per line on stdout
# Returns:
#   0, always: an expression with no selector simply names no labels
obsq_logql_label_names() {
  local query="${1:-}" chunk entry
  while IFS= read -r chunk; do
    [ -n "${chunk}" ] || continue
    while IFS= read -r entry; do
      entry="${entry#"${entry%%[![:space:]]*}"}"
      [[ ${entry} =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*(=~|!~|!=|=) ]] || continue
      printf '%s\n' "${BASH_REMATCH[1]}"
    done <<<"$(printf '%s\n' "${chunk}" | tr ',' '\n')"
  done < <(printf '%s' "${query}" | grep -o '{[^}]*}' | sed 's/^{//;s/}$//')
  return 0
}

# @function obsq_logql_rejects
# Print the label names a LogQL expression asks Loki to filter on that Loki does
# not guarantee, sorted and deduped. A fifth label is not a slow query, it is a
# query that can only ever be empty, so the CLI refuses it before the first
# request and hands the caller the set that does work.
# Globals:
#   OBSQ_ALLOWED_LABELS
# Arguments:
#   $1 - the LogQL expression
# Outputs:
#   One offending label name per line on stdout
# Returns:
#   0 when at least one label is outside the guaranteed set, 1 when every label
#   the expression names is one Loki carries
obsq_logql_rejects() {
  local query="${1:-}" name allowed ok found=0
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    ok=0
    for allowed in ${OBSQ_ALLOWED_LABELS}; do
      if [[ ${name} == "${allowed}" ]]; then
        ok=1
        break
      fi
    done
    if [ "${ok}" = "0" ]; then
      printf '%s\n' "${name}"
      found=1
    fi
  done <<<"$(obsq_logql_label_names "${query}" | sort -u)"
  if [ "${found}" = "1" ]; then
    return 0
  fi
  return 1
}

# @function obsq_urlencode
# Percent-encode one string for a query parameter. Unreserved characters stay
# literal so the URL in the report stays readable; everything else becomes %XX.
# Callers must run obsq_assert_ascii first: this encodes a byte at a time, and a
# multibyte input would be encoded wrong rather than refused.
# Globals:
#   None
# Arguments:
#   $1 - the string to encode
# Outputs:
#   The encoded string on stdout, with no trailing newline
# Returns:
#   0, always
obsq_urlencode() {
  local text="${1:-}" out="" char="" i=0
  local len="${#text}"
  while [ "${i}" -lt "${len}" ]; do
    char="${text:i:1}"
    case "${char}" in
      [A-Za-z0-9._~-]) out="${out}${char}" ;;
      *) out="${out}$(LC_ALL=C printf '%%%02X' "'${char}")" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "${out}"
  return 0
}

# @function obsq_since_seconds
# Convert one window this CLI accepts to seconds. The grammar is deliberately the
# small subset of Go's duration syntax the compose bundle itself uses (h and d in
# the retention keys, m in the scrape interval): no sign, no fractions, no
# compound units, because a window a human cannot eyeball is a window that quietly
# scans the whole retention period.
# Globals:
#   None
# Arguments:
#   $1 - the window, as 15m, 1h, 24h, 7d
# Outputs:
#   The whole number of seconds on stdout
# Returns:
#   0 when the window parsed, 1 when it did not
obsq_since_seconds() {
  local dur="${1:-}"
  [[ ${dur} =~ ^([0-9]+)([smhd])$ ]] || return 1
  local n="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}" mult=1
  case "${unit}" in
    s) mult=1 ;;
    m) mult=60 ;;
    h) mult=3600 ;;
    d) mult=86400 ;;
  esac
  printf '%s' "$((10#${n} * mult))"
  return 0
}

# @function obsq_datasource
# Resolve one datasource name to its provisioned uid and type. The CLI addresses
# datasources by UID through Grafana's proxy, so a name nobody provisioned has to
# be refused here rather than answered with a 404 the caller cannot read.
# Globals:
#   OBSQ_DATASOURCES
# Arguments:
#   $1 - the datasource name
# Outputs:
#   uid<TAB>type on stdout when the name is provisioned
# Returns:
#   0 when it is, 1 when it is not
obsq_datasource() {
  local want="${1:-}" entry uid type
  for entry in "${OBSQ_DATASOURCES[@]}"; do
    uid="${entry%%:*}"
    type="${entry#*:}"
    if [[ ${uid} == "${want}" ]]; then
      printf '%s\t%s\n' "${uid}" "${type}"
      return 0
    fi
  done
  return 1
}

# @function obsq_query_path
# Print the range-query path one datasource type serves, which is the path
# Grafana's proxy puts after /api/datasources/proxy/uid/<uid>. The two query
# dialects live at different paths and only the type says which.
# Globals:
#   None
# Arguments:
#   $1 - the datasource type, as obsq_datasource prints it
# Outputs:
#   The path on stdout, with no trailing newline
# Returns:
#   0 for a known type, 1 for any other
obsq_query_path() {
  case "${1:-}" in
    prometheus) printf '%s' '/api/v1/query_range' ;;
    loki) printf '%s' '/loki/api/v1/query_range' ;;
    tempo) printf '%s' '/api/v1/query_range' ;;
    *) return 1 ;;
  esac
  return 0
}

# @function obsq_labels_path
# Print the labels path one datasource type serves. This is what --self-test asks
# instead of a query: a labels call proves the datasource resolves, the token is
# accepted for it, and the backend answers behind Grafana, without pulling a
# single sample back over the wire.
# Globals:
#   None
# Arguments:
#   $1 - the datasource type, as obsq_datasource prints it
# Outputs:
#   The path on stdout, with no trailing newline
# Returns:
#   0 for a known type, 1 for any other
obsq_labels_path() {
  case "${1:-}" in
    prometheus) printf '%s' '/api/v1/labels' ;;
    loki) printf '%s' '/loki/api/v1/labels' ;;
    tempo) printf '%s' '/api/v1/labels' ;;
    *) return 1 ;;
  esac
  return 0
}

# @function obsq_read_token
# Print the read-only service-account token, from a file and only from a file. The
# token never appears in argv, so it never reaches a process listing, a shell
# history line, or a test stub's argv log. A value carrying anything outside the
# alphabet Grafana mints (a newline above all) is refused rather than carried
# forward: this value goes into a curl config line and a header, where a CR or LF
# is an injected second header.
# Globals:
#   None
# Arguments:
#   $1 - path of the token file
# Outputs:
#   The token on stdout, with no trailing newline
# Returns:
#   0 with the token, 1 when the file is absent, blank, or holds no token-shaped
#   line, 2 when it exists and cannot be read
obsq_read_token() {
  local path="${1:-}" line=""
  [ -n "${path}" ] || return 1
  [ -e "${path}" ] || return 1
  [ -f "${path}" ] || return 2
  [ -r "${path}" ] || return 2
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "${line}" ] || continue
    if [[ ! ${line} =~ ^[A-Za-z0-9._~-]+$ ]]; then
      return 1
    fi
    printf '%s' "${line}"
    return 0
  done <"${path}"
  return 1
}

# @function obsq_redact
# Replace every occurrence of the token with OBSQ_TOKEN_REDACTION. Every string
# this CLI prints passes through here - the report lines, curl's own complaint,
# and the response body, which is the one place a token can come back unasked for,
# because a log line is free to quote the request that wrote it. The pattern is a
# bash glob, so the four characters a glob would read as syntax are escaped
# first; without that a token holding a * would silently stop matching itself.
# Globals:
#   GRAFANA_TOKEN, OBSQ_TOKEN_REDACTION
# Arguments:
#   $1 - the text to scrub
# Outputs:
#   The scrubbed text on stdout, with no trailing newline
# Returns:
#   0, always
obsq_redact() {
  local text="${1:-}" pattern="${GRAFANA_TOKEN:-}"
  if [ -z "${pattern}" ]; then
    printf '%s' "${text}"
    return 0
  fi
  pattern="${pattern//\\/\\\\}"
  pattern="${pattern//\*/\\*}"
  pattern="${pattern//\?/\\?}"
  pattern="${pattern//\[/\\[}"
  printf '%s' "${text//${pattern}/${OBSQ_TOKEN_REDACTION}}"
  return 0
}

# @function obsq_is_refused
# Succeed for the answers that mean the bundle is simply not running, which for a
# query CLI is the profile-off look and never a fault. Three shapes say it:
# nothing listening on the published port (curl exit 7 and its two complaints),
# no daemon for the in-network transport to join, and a project network that does
# not exist because no compose up ever ran. The whole bundle rides the
# observability profile, so a refused connection is the normal answer on a box
# that never enabled it.
# Globals:
#   None
# Arguments:
#   $1 - the transport's exit status; $2 - its first complaint line
# Outputs:
#   None
# Returns:
#   0 when nothing is up, 1 for every other failure
obsq_is_refused() {
  local rc="${1:-}" err="${2:-}"
  if [ "${rc}" = "7" ]; then
    return 0
  fi
  case "${err}" in
    *"Connection refused"* | *"Couldn't connect"* | *"Could not resolve host"*) return 0 ;;
    *"Cannot connect to the Docker daemon"* | *"No such object"* | *"network "*"_default not found"*)
      return 0
      ;;
  esac
  return 1
}

# @function obsq_is_no_data
# Succeed when a 2xx body carries nothing: no series, no stream, no alert, no
# dashboard. This is the state a caller most often mistakes for a broken bundle,
# so it has to be distinguishable from both an empty box and a dead one. Prometheus
# and Loki answer an empty range with "result":[], Alertmanager with [], and
# Grafana's search with [] as well.
# Globals:
#   None
# Arguments:
#   $1 - the response body
# Outputs:
#   None
# Returns:
#   0 when the body holds no row, 1 when it holds at least one
obsq_is_no_data() {
  local body="${1:-}"
  body="${body//[[:space:]]/}"
  if [ -z "${body}" ]; then
    return 0
  fi
  case "${body}" in
    '[]' | '{}' | 'null') return 0 ;;
    *'"result":[]'* | *'"result":null'*) return 0 ;;
  esac
  return 1
}

# @function obsq_answer_shape
# Name which of the four shapes one transport answer is, which is the whole
# contract of this CLI: a box that never enabled the bundle, a box that enabled it
# and holds nothing, and a box that is broken are three different answers and must
# never collapse into one. A 401 and a 403 are errors rather than the off state:
# something is up, and it is refusing the credential.
# Globals:
#   None
# Arguments:
#   $1 - the transport's exit status; $2 - the HTTP status code; $3 - the
#   transport's first complaint; $4 - the response body
# Outputs:
#   One of off, error, nodata, data on stdout, with no trailing newline
# Returns:
#   0, always: the shape is a result, never an abort
obsq_answer_shape() {
  local rc="${1:-}" code="${2:-}" err="${3:-}" body="${4:-}"
  if obsq_is_refused "${rc}" "${err}"; then
    printf 'off'
    return 0
  fi
  if [ "${rc}" != "0" ] || [ -z "${code}" ] || [ "${code}" = "000" ]; then
    printf 'error'
    return 0
  fi
  case "${code}" in
    2??) ;;
    *)
      printf 'error'
      return 0
      ;;
  esac
  if obsq_is_no_data "${body}"; then
    printf 'nodata'
  else
    printf 'data'
  fi
  return 0
}

# @function obsq_result_count
# Print how many rows one body carries, for the ok: line, so a caller learns
# whether it is looking at the whole answer or at a limit-truncated one. Counting
# is done by the field every row of that shape must carry, per shape, rather than
# by parsing JSON: this CLI ships no JSON parser dependency and the field is
# stable in each API's own output.
# Globals:
#   None
# Arguments:
#   $1 - the shape: series, streams, alerts, or dashboards; $2 - the body
# Outputs:
#   The count on stdout
# Returns:
#   0, always: an unrecognised shape counts zero rather than failing the run
obsq_result_count() {
  local shape="${1:-}" body="${2:-}" needle="" count=""
  case "${shape}" in
    series) needle='"metric":{' ;;
    streams) needle='"stream":{' ;;
    alerts) needle='"labels":{' ;;
    dashboards) needle='"type":"dash"' ;;
    *) needle="" ;;
  esac
  if [ -z "${needle}" ]; then
    printf '0'
    return 0
  fi
  count="$(printf '%s' "${body}" | grep -oF "${needle}" 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' "${count:-0}"
  return 0
}
