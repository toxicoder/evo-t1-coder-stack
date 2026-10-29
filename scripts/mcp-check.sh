#!/usr/bin/env bash
#
# ## mcp-check.sh - prove the Grok Build MCP lanes a session actually gets
#
# The stack declares three MCP servers in every workspace's ~/.grok/config.toml
# (searxng for search, context7 for library docs, github for the repository),
# each behind a template boolean that defaults to true. Declaring a lane is not
# the same as having it: the binary can be absent from an image older than the
# templates, the credential can be empty, a hand-edited config can lose the
# stack marker so the render never touches it again, and the backend can be
# down. Each of those leaves a session with one fewer tool and no message.
#
# This CLI reads the config the way the CLI will, and answers one question per
# declared lane: is it declared, is its binary there, is its credential set, is
# its backend reachable, and did the handshake succeed. It runs from the stack
# host or from inside a workspace; nothing here needs the docker daemon.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:mcp-check -- [--config PATH] [--lanes LIST] [--url URL]
#                                       [--no-handshake] [--strict] [--json] [-h|--help]
#
# Options (accepted anywhere in argv):
#   --config <path>       the Grok config to read (default $HOME/.grok/config.toml)
#   --lanes <list>        comma-separated lanes to require (default searxng,context7)
#   --url <url>           SearXNG base URL for the search lane (default
#                         $SEARXNG_URL, then http://host.docker.internal:8181)
#   --no-handshake        skip `grok mcp doctor --json` and judge files only
#   --strict              a warning is a failure (exit 1 on a warning too)
#   --json                one machine-readable object on stdout, prose on stderr
#   -h, --help            print the usage block and exit 0
#
# Output: the house vocabulary - "== section ==", "-> phase", "ok:", "warning:",
#   "note:", "error:", and a closing "summary: N ok, W warnings, F failed".
# Exit codes: 0 with no failures (warnings allowed unless --strict), 1 with at
#   least one failure (or a warning under --strict), 2 on a usage error.
#
# A missing binary is a warning, not a failure: it means the running image
# predates the npm bake in images/dev/Dockerfile, which is drift an operator
# fixes with an image rebuild, and a workspace still boots and works without
# that one lane. A lane the config never declared is a failure, because the
# default render declares it and something took it away.
#
# Related: scripts/search-check.sh (the SearXNG service hop this CLI only
#   probes), grok mcp doctor (the handshake this CLI reads rather than repeats),
#   docs/troubleshooting.md (the runbooks this feeds).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# @function resolve_repo_root
# Print the checkout this run reads its pins from: the first candidate holding a
# docker-compose.yml marker. A Bazel sandbox holds a copy of the tree, so the
# probe is a marker file and never a cwd assumption.
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
# Print the path one helper is reachable from: the resolved root first, then this
# script's own directory, so a runfiles copy still finds both halves.
# Globals:
#   SELF_DIR
# Arguments:
#   $1 - helper file name, relative to the lib directory
#   $2 - resolved repo root, possibly empty
# Outputs:
#   The helper path on stdout, or one complaint line on stderr
# Returns:
#   0 when the helper was found, 1 otherwise
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
  printf 'error: mcp-check cannot run without its helpers: no scripts/lib/common.sh above\n' >&2
  exit 1
}
REPORT_PY="$(find_lib mcp_lane_report.py "${REPO_ROOT_RESOLVED}")" || {
  printf 'error: mcp-check cannot run without its parser: no scripts/lib/mcp_lane_report.py above\n' >&2
  exit 1
}
# shellcheck source=/dev/null
source "${COMMON_LIB}"

DEFAULT_LANES="searxng,context7"
DEFAULT_SEARCH_URL="http://host.docker.internal:8181"
# The two spellings of stack ownership, kept in step with STACK_MARKER_TEXT and
# STACK_MARKER_TOML in scripts/lib/config_seed.sh. The comment form is what the
# render writes; the plain key is what survives the CLI rewriting this file.
STACK_MARKER="managed-by: evo-t1-coder-stack"
STACK_MARKER_TOML="__evoT1Stack = true"
# CONFIG_MANAGED - 1 once the config section found an ownership marker; it is
# what tells the lane report who owns this file.
CONFIG_MANAGED=0
JSON_FINDINGS=""
STRICT=0

# @function finish
# Close the run: the summary line, the machine-readable object under --json, and
# the exit code that answers the same question both printouts just answered.
# Globals:
#   JSON_MODE, JSON_FINDINGS, STRICT, SUMMARY_OK, SUMMARY_WARN, SUMMARY_FAIL,
#   CONFIG, LANE_LIST
# Arguments:
#   None
# Outputs:
#   The summary, and one JSON object on stdout under --json
# Returns:
#   Nothing: exits 0, or 1 on a failure (or a warning under --strict)
finish() {
  summary
  if [ -n "${JSON_MODE:-}" ]; then
    printf '{"config":"%s","lanes":"%s","ok":%d,"warnings":%d,"failed":%d,"findings":[%s]}\n' \
      "$(json_escape "${CONFIG:-}")" "$(json_escape "${LANE_LIST:-}")" \
      "${SUMMARY_OK:-0}" "${SUMMARY_WARN:-0}" "${SUMMARY_FAIL:-0}" "${JSON_FINDINGS:-}"
  fi
  if [ "${SUMMARY_FAIL:-0}" -gt 0 ]; then
    exit 1
  fi
  if [ "${STRICT}" = "1" ] && [ "${SUMMARY_WARN:-0}" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

# @function usage
# Print how to run this CLI.
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
usage: bazelisk run //scripts:mcp-check -- [--config PATH] [--lanes LIST] [--url URL]
                                          [--no-handshake] [--strict] [--json] [-h|--help]

Proves the Grok Build MCP lanes a session gets: the declared block, its binary,
its credential, its backend, and its handshake. Runs on the stack host or inside
a workspace; needs no docker.

Options: --config (default $HOME/.grok/config.toml), --lanes (default
searxng,context7), --url (SearXNG base for the search lane; default
$SEARXNG_URL then http://host.docker.internal:8181), --no-handshake (skip
`grok mcp doctor --json`), --strict (a warning fails the run), --json (one
object on stdout, prose on stderr), -h/--help.

Exit: 0 clean or warned, 1 on any failure (or a warning under --strict),
2 on a usage error.
USAGE
}

# @function usage_error
# Print one usage complaint and exit 2, so a typo is never mistaken for a result.
# Globals:
#   None
# Arguments:
#   $1 - the complaint
# Outputs:
#   The complaint on stderr, plus the usage block on stdout
# Returns:
#   Nothing: exits 2
usage_error() {
  printf 'error: %s\n' "$1" >&2
  usage
  exit 2
}

# @function tool_pin
# Print the pinned version of one golden-image npm package, or the empty string
# when the pin file or the key is missing (the caller then names no version).
# Globals:
#   REPO_ROOT_RESOLVED
# Arguments:
#   $1 - the key in images/dev/tool-versions.env, e.g. SEARXNG_MCP_SERVER_VERSION
# Outputs:
#   The version on stdout, nothing when unknown
# Returns:
#   0, always
tool_pin() {
  local key="${1:-}" pins="" value=""
  pins="${REPO_ROOT_RESOLVED:-}/images/dev/tool-versions.env"
  [ -n "${pins}" ] && [ -f "${pins}" ] || return 0
  value="$(sed -n "s|^${key}=||p" "${pins}" | tail -n 1)" || value=""
  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "${value}"
}

# @function lane_remedy
# Print the install command that restores a stdio lane's binaries, built from the
# pins in images/dev/tool-versions.env so the advice matches this checkout.
# Globals:
#   REPO_ROOT_RESOLVED (via tool_pin)
# Arguments:
#   $1 - lane name (searxng or context7)
# Outputs:
#   The remedy text on stdout, empty for a lane with no npm package
# Returns:
#   0, always
lane_remedy() {
  local lane="${1:-}" packages=""
  case "${lane}" in
    searxng) packages="searxng-mcp-server:SEARXNG_MCP_SERVER_VERSION" ;;
    context7) packages="mcp-cache-proxy:MCP_CACHE_PROXY_VERSION @upstash/context7-mcp:CONTEXT7_MCP_VERSION" ;;
    *) return 0 ;;
  esac
  local pair name key version
  printf 'npm i -g --prefix /opt/npm-global'
  for pair in ${packages}; do
    name="${pair%%:*}"
    key="${pair##*:}"
    version="$(tool_pin "${key}")"
    if [ -n "${version}" ]; then
      printf ' %s@%s' "${name}" "${version}"
    else
      printf ' %s' "${name}"
    fi
  done
}

# @function config_search_url
# Print the SEARXNG_URL the searxng block itself declares, which is the address
# the CLI will dial, or nothing when the block names none.
# Globals:
#   None
# Arguments:
#   $1 - the config path to read
# Outputs:
#   The URL on stdout, nothing when absent
# Returns:
#   0, always
config_search_url() {
  local cfg="${1:-}"
  [ -f "${cfg}" ] || return 0
  awk '/^\[mcp_servers\.searxng\]/{f=1} /^\[/ && !/mcp_servers\.searxng/{f=0} f' \
    "${cfg}" 2>/dev/null |
    sed -n 's/.*SEARXNG_URL[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

# @function probe_search
# Print the HTTP status the SearXNG service answers with, or no-answer when the
# box never replied. This is the reachability half; scripts/search-check.sh is
# the per-engine depth half.
# Globals:
#   None
# Arguments:
#   $1 - the base URL to probe
# Outputs:
#   The three-digit status, or the literal no-answer, on stdout
# Returns:
#   0, always
probe_search() {
  local url="${1:-}" code=""
  command -v curl >/dev/null 2>&1 || {
    printf 'no-curl'
    return 0
  }
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    "${url}/search?q=mcp-check&format=json" 2>/dev/null)" || code=""
  if [ -z "${code}" ] || [ "${code}" = "000" ]; then
    printf 'no-answer'
  else
    printf '%s' "${code}"
  fi
}

# @function probe_search_depth
# Print how many results the service actually returns for one lookup, or the
# literal no-answer when the request itself did not complete.
#
# The status code cannot answer the question this CLI is asked. An instance
# whose engines are all parked answers 200 with an empty result set, and an
# agent holding that reply is no better off than with the service down: its
# search tool returns nothing. Measured on this stack, that is a reachable
# state - google refuses "access denied" and duckduckgo a CAPTCHA, and SearXNG
# parks each for a while (search.suspended_times) - so a check that stopped at
# the status line called the lane healthy while every agent search came back
# empty.
#
# The query is a plain factual lookup rather than the "mcp-check" string the
# reachability probe sends, because a nonsense string can legitimately find
# nothing and that would read as a broken lane. Counting "url" keys is how
# scripts/search-check.sh counts results, so the two cannot disagree.
# Globals:
#   None
# Arguments:
#   $1 - the base URL to probe
# Outputs:
#   A result count, `no-answer`, or `no-curl`, on stdout
# Returns:
#   0, always
probe_search_depth() {
  local url="${1:-}" body="" count=""
  command -v curl >/dev/null 2>&1 || {
    printf 'no-curl'
    return 0
  }
  body="$(curl -sS --noproxy '*' --max-time 15 -G "${url}/search" \
    --data-urlencode "format=json" \
    --data-urlencode "q=what language was the linux kernel written in" \
    2>/dev/null)" || body=""
  if [ -z "${body}" ]; then
    printf 'no-answer'
    return 0
  fi
  count="$(printf '%s' "${body}" | grep -o '"url"[[:space:]]*:' 2>/dev/null |
    wc -l | tr -d '[:space:]')"
  case "${count}" in '' | *[!0-9]*) count="0" ;; esac
  printf '%s' "${count}"
}

# @function take_doctor
# Capture `grok mcp doctor --json` into a file for the parser to read.
# Globals:
#   DOCTOR_FILE
# Arguments:
#   None
# Outputs:
#   The doctor JSON at DOCTOR_FILE, or one note when grok is missing or slow
# Returns:
#   0 when a report was captured, 1 otherwise
take_doctor() {
  local status=0
  if ! has_tool grok; then
    note "grok is not on PATH here - the handshake section is skipped; run this inside a workspace for it"
    return 1
  fi
  # doctor exits non-zero when a server is unhealthy, which is a finding and not
  # a missing report: keep whatever JSON it printed and let the parser judge it.
  timeout 180 grok mcp doctor --json >"${DOCTOR_FILE}" 2>/dev/null || status=$?
  if [ ! -s "${DOCTOR_FILE}" ]; then
    warn "grok mcp doctor --json gave no report (status ${status}) - judging this run from the config and the filesystem alone"
    return 1
  fi
  return 0
}

# @function emit_finding
# Print one finding in the house vocabulary and keep it for the --json object, so
# the two renderings of a run can never disagree.
# Globals:
#   JSON_MODE, JSON_FINDINGS (appended to only under JSON_MODE)
# Arguments:
#   $1 - ok | warn | note | fail
#   $2 - the finding text, without the status prefix
# Outputs:
#   The house-vocabulary line
# Returns:
#   0
emit_finding() {
  local status="${1:-}" text="${2:-}"
  case "${status}" in
    ok) ok "${text}" ;;
    warn) warn "${text}" ;;
    note) note "${text}" ;;
    *) fail_item "${text}" ;;
  esac
  if [ -n "${JSON_MODE:-}" ]; then
    if [ -n "${JSON_FINDINGS}" ]; then
      JSON_FINDINGS="${JSON_FINDINGS},"
    fi
    JSON_FINDINGS="${JSON_FINDINGS}{\"status\":\"${status}\",\"text\":\"$(json_escape "${text}")\"}"
  fi
  return 0
}

# @function report_lanes
# Ask the parser once about every required lane, then print each lane's findings
# under its own phase line. One parser call keeps the counters honest: a finding
# is counted where it was measured, never once per lane. The parser is told when
# the file carries no ownership marker, so a lane missing from a file nobody owns
# blames that file rather than a push gate.
# Globals:
#   CONFIG, REPORT_PY, DOCTOR_FILE, DOCTOR_OK, LANE_LIST, SEARCH_URL,
#   CONFIG_MANAGED
# Arguments:
#   None
# Outputs:
#   ok/warning/note/error lines for every lane, plus the search probe
# Returns:
#   0, always (the counters decide the exit code)
report_lanes() {
  local findings="" line lane_name check status detail remedy="" lane
  local -a doctor_arg=() unmanaged_arg=()
  [ "${DOCTOR_OK}" = "1" ] && doctor_arg=(--doctor "${DOCTOR_FILE}")
  [ "${CONFIG_MANAGED}" = "1" ] || unmanaged_arg=(--unmanaged)
  findings="$(python3 "${REPORT_PY}" --config "${CONFIG}" --lanes "${LANE_LIST}" \
    "${doctor_arg[@]}" "${unmanaged_arg[@]}" 2>/dev/null)" || findings=""

  for lane in ${LANE_LIST//,/ }; do
    phase "checking ${lane}"
    while IFS= read -r line; do
      [ -n "${line}" ] || continue
      IFS=$'\t' read -r lane_name check status detail <<<"${line}"
      [ "${lane_name}" = "${lane}" ] || continue
      remedy=""
      if [ "${status}" = "warn" ] && [ "${check}" = "command" ]; then
        remedy=" - $(lane_remedy "${lane}")"
      fi
      emit_finding "${status}" "${lane}: ${check} ${detail}${remedy}"
    done <<<"${findings}"
    if [ "${lane}" = "searxng" ]; then
      local code depth
      code="$(probe_search "${SEARCH_URL}")"
      case "${code}" in
        2*)
          # A 2xx proves something is listening; the lane is only useful when it
          # returns rows. Reporting the hop as healthy on the status alone is
          # what let an instance with every engine parked pass this check while
          # every agent search came back empty.
          depth="$(probe_search_depth "${SEARCH_URL}")"
          case "${depth}" in
            no-curl)
              emit_finding ok "searxng: service ${SEARCH_URL} answered HTTP ${code}"
              ;;
            no-answer)
              emit_finding warn "searxng: service ${SEARCH_URL} answered HTTP ${code}, but the results request brought nothing back at all"
              ;;
            0)
              emit_finding warn "searxng: service ${SEARCH_URL} answered HTTP ${code} with zero results for a plain lookup, so an agent's searches come back empty - the engines are most likely parked by their backends; run 'bazelisk run //scripts:search-check' to name them"
              ;;
            *)
              emit_finding ok "searxng: service ${SEARCH_URL} answered HTTP ${code} with ${depth} result(s)"
              ;;
          esac
          ;;
        no-curl) emit_finding warn "searxng: curl is not installed here, so the service hop went unprobed" ;;
        no-answer) emit_finding fail "searxng: ${SEARCH_URL} gave no HTTP answer - the SearXNG service is down or the URL is wrong" ;;
        *) emit_finding warn "searxng: ${SEARCH_URL} answered HTTP ${code}, which is not 2xx" ;;
      esac
    fi
  done

  # Servers the config declares outside the required lanes: reported, not judged.
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    IFS=$'\t' read -r lane_name check status detail <<<"${line}"
    if [ "${status}" = "note" ]; then
      emit_finding note "${lane_name}: ${check} ${detail}"
    fi
  done <<<"${findings}"
  return 0
}

# @function main
# Parse argv, walk the sections, summarize, and answer with the exit code.
# Globals:
#   CONFIG, LANE_LIST, SEARCH_URL, DOCTOR_FILE, DOCTOR_OK, STRICT, JSON_MODE,
#   CONFIG_MANAGED, STACK_MARKER, STACK_MARKER_TOML
# Arguments:
#   "$@" - the command line
# Outputs:
#   The report on stdout (stderr under --json), or the usage block
# Returns:
#   0 clean or warned, 1 on failure, 2 on a usage error
main() {
  local config="" lanes="${DEFAULT_LANES}" url="" handshake=1 strict=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [ $# -ge 2 ] || usage_error "--config needs a path"
        config="$2"
        shift 2
        ;;
      --lanes)
        [ $# -ge 2 ] || usage_error "--lanes needs a comma-separated list"
        lanes="$2"
        shift 2
        ;;
      --url)
        [ $# -ge 2 ] || usage_error "--url needs a URL"
        url="$2"
        shift 2
        ;;
      --no-handshake)
        handshake=0
        shift
        ;;
      --strict)
        strict=1
        shift
        ;;
      --json)
        JSON_MODE=1
        export JSON_MODE
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage_error "unknown option: $1" ;;
    esac
  done
  [ -n "${JSON_MODE:-}" ] || unset JSON_MODE

  [[ ${lanes} =~ ^[A-Za-z0-9_-]+(,[A-Za-z0-9_-]+)*$ ]] ||
    usage_error "--lanes wants comma-separated names like searxng,context7"

  CONFIG="${config:-${HOME:-/home/coder}/.grok/config.toml}"
  # --url wins outright; otherwise dial what the block declares, since that is
  # the address the CLI will use, then the agent env, then the shipped default.
  local declared_url=""
  [ -n "${url}" ] || declared_url="$(config_search_url "${CONFIG}")"
  SEARCH_URL="${url:-${declared_url:-${SEARXNG_URL:-${DEFAULT_SEARCH_URL}}}}"
  SEARCH_URL="${SEARCH_URL%/}"
  LANE_LIST="${lanes}"
  DOCTOR_FILE="$(mktemp "${TMPDIR:-/tmp}/evoT1McpDoctor.XXXXXX")"
  trap 'rm -f "${DOCTOR_FILE}"' EXIT
  DOCTOR_OK=0
  STRICT="${strict}"

  section "config"
  if [ ! -f "${CONFIG}" ]; then
    emit_finding fail "no config at ${CONFIG} - no workspace has rendered one here"
    finish
  fi
  emit_finding ok "readable at ${CONFIG}"
  if grep -qsF -e "${STACK_MARKER}" -e "${STACK_MARKER_TOML}" "${CONFIG}"; then
    CONFIG_MANAGED=1
    emit_finding ok "stack-managed (the startup render still owns this file)"
  else
    CONFIG_MANAGED=0
    emit_finding warn "no ${STACK_MARKER} marker and no ${STACK_MARKER_TOML} key - the stack stopped managing this file, so its default lanes and model catalog never reach it; delete it and restart, or re-materialize with 'bazelisk run //scripts:seed-dev-env -- --force'"
  fi

  section "handshake"
  if [ "${handshake}" = "1" ]; then
    if take_doctor; then
      DOCTOR_OK=1
      emit_finding ok "captured a grok mcp doctor report"
    fi
  else
    emit_finding note "--no-handshake: judging from the config, the filesystem and the service probe alone"
  fi

  section "lanes"
  report_lanes

  finish
}

main "$@"
