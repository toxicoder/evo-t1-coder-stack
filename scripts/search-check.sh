#!/usr/bin/env bash
# shellcheck shell=bash
#
# ## search-check.sh - prove whether the self-hosted search path answers, per engine.
#
# One question, answered from this machine: an agent in a workspace calls its
# search tool and gets nothing useful back. Is SearXNG not running at all, is it
# running but every backend engine refuses it, is the json format disabled by
# searxng/settings.yml, or is the search path fine and the fault somewhere
# above the search box? This script probes one HTTP GET per engine x query pair
# and reports what answered, so the operator can tell those four apart without
# reading a container log and without guessing.
#
# The four outcomes, and why the split matters:
#   ok     HTTP 200 with at least one result: the path answers for that pair.
#   empty  HTTP 200 with zero results. Either an engine refuses this instance
#          (rate limit, dead API key, bot wall - SearXNG reports those INSIDE a
#          200 body, not as an error) or the query is simply unfindable. That is
#          why the default query set carries one deliberately obscure string:
#          it is a transport probe and is EXPECTED to come back empty on a
#          healthy engine. Pass --queries with real lookups when you want an
#          exit code that means "search works end to end"; with the shipped
#          defaults a healthy box still exits 1, on that one obscure string.
#   403    HTTP 403. Not an engine fault and not a network fault: search.formats
#          does not list json, so the json API is switched off for every engine
#          at once. Fix searxng/settings.yml, restart the service, re-run this.
#   other  Anything else: connection refused, a 404 from whatever else lives on
#          that port, a 5xx, or a pair that spent the whole --timeout cap and
#          got cut off. "Nothing answered" is a RESULT here, printed as such.
#
# The sweep never stops at the first failure and no pair can abort the loop: one
# dead engine must not hide the state of the five that work, which is the whole
# reason this reads as a table instead of dying at the first curl.
#
# Result counting: the count of one pair is the number of "url" keys in the
# reply body. A SearXNG results envelope carries one per result and none in its
# wrapper keys, so "no url key" reads as an empty answer and not as a broken
# parse; a body that is not an envelope at all counts as empty too, which is the
# honest answer, because an agent handed that body was given nothing either.
#
# Usage (Bazel is the entry point; every example is the whole command):
#   bazelisk run //scripts:search-check
#   bazelisk run //scripts:search-check -- --json
#   bazelisk run //scripts:search-check -- --url http://127.0.0.1:8181 --timeout 5
#   bazelisk run //scripts:search-check -- --engines google,brave
#   bazelisk run //scripts:search-check -- --queries "python 3.12 datetime.fromisoformat"
#   SEARXNG_URL=http://127.0.0.1:8181 bazelisk run //scripts:search-check
#   bazelisk run //scripts:search-check -- --help
#
# Options (accepted anywhere in argv):
#   --url URL        where to probe (default: $SEARXNG_URL when set, else
#                    http://127.0.0.1:8181, the loopback port the compose file
#                    publishes for the searxng service)
#   --engines LIST   comma-separated engines, probed in this order by default:
#                    google,duckduckgo,brave,wikipedia,stackoverflow,github
#   --queries LIST   comma-separated queries. The default trio is one factual
#                    lookup, one library/version-sensitive lookup and one
#                    deliberately obscure string (see the note above).
#   --timeout SECS   per-request cap, applied twice over: timeout(1) around
#                    curl and curl's own --max-time (default 20)
#   --json           one flat JSON object on stdout, every value numeric; the
#                    table is not printed in this mode, and the per-pair
#                    records, the verdict and every other prose line go to
#                    stderr instead, so `2>/dev/null` silences the commentary
#                    and `| jq` still parses. The exit code does not change.
#                    With nothing measured (no curl) there is no object: an
#                    answer about nothing would be a number that means nothing.
#   -h, --help       print this usage and exit 0
#
# Exit codes: 0 when every pair answered with at least one result; 1 when one or
# more pairs came back empty or errored - the actionable answer, printed either
# way, and the reason the table still prints; 2 on a usage error (an unknown
# flag, a flag after --timeout or --engines that names no engine, a --timeout
# that is not a whole number of seconds), always before the first probe; and 0
# with one printed reason when curl is not on PATH, because nothing could be
# measured and a check that silently skipped is a check that never ran.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# @function resolve_repo_root
# Print the checkout root this run reads from: the first candidate that holds a
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
  # PWD first of the two path probes: under `bazelisk run` the cwd is the
  # checkout, and the two SELF_DIR candidates are what a runfiles copy or a
  # foreign cwd falls back to.
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
# Print the path one sourced lib is reachable from: the resolved root first,
# then this script's own directory. Under `bazelisk run //scripts:search-check`
# both exist inside the runfiles copy, and this is the only reason they do:
# //scripts:doc_sources carries scripts/**/*.sh into runfiles beside the entry
# script, so the sourced half has to be found by probing, not assumed.
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
    candidates+=("${root}/scripts/lib/${name}" "${root}/scripts/lib/${name}.gz")
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
  printf 'error: search-check cannot run without its helpers: no scripts/lib/common.sh above\n' >&2
  exit 1
}

# shellcheck source=lib/common.sh disable=SC1091
source "${COMMON_LIB}"

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
usage: bazelisk run //scripts:search-check -- [--url URL] [--engines LIST] [--queries LIST]
                    [--timeout SECS] [--json] [--help]

Proves whether the self-hosted search path actually returns results, and for
which engines, by probing <url>/search?format=json once per engine x query
pair. The answer is per engine, so "google works and brave does not" is a
report this script gives and "search is down" is not.

The four per-pair outcomes: ok (200 with results), empty (200 with none),
403 (search.formats lacks json, which is a config fault and not an engine
fault), other (refused, 404, 5xx, or cut off by --timeout).

Options: --url (default $SEARXNG_URL or http://127.0.0.1:8181), --engines,
--queries, --timeout (default 20 seconds per request, spent twice: timeout(1)
and curl --max-time), --json (one flat object on stdout; the table is not
printed and the records and prose go to stderr), -h/--help.

The default query set names one deliberately obscure string: it is a
transport probe and answers empty even on a healthy engine, so a green run
needs --queries with real lookups.

Exit codes: 0 = every pair returned results (or curl is missing and nothing
could be measured); 1 = one or more pairs came back empty or errored; 2 =
usage error.

Run it as a Bazel target from anywhere:
  bazelisk run //scripts:search-check
  bazelisk run //scripts:search-check -- --json
  bazelisk run //scripts:search-check -- --queries "python 3.12 datetime.fromisoformat"
USAGE
}

# @function usage_error
# Print one usage complaint and exit, so a typo cannot be mistaken for a result.
# Globals:
#   None
# Arguments:
#   $* - the complaint, without the "error: " prefix
# Outputs:
#   The complaint on stderr, plus the usage block on stdout
# Returns:
#   Does not return; exits 2
usage_error() {
  err "$*"
  usage
  exit 2
}

# ── knobs ────────────────────────────────────────────────────────────────────

# The three defaults the operator who wrote the contract asked for: a factual
# lookup, a library/version-sensitive lookup, and one string nobody has ever
# indexed. The third one is a transport probe, not a question.
DEFAULT_ENGINES="google,duckduckgo,brave,wikipedia,stackoverflow,github"
DEFAULT_QUERIES="what language was the linux kernel written in,python 3.12 datetime.fromisoformat format change,zzyzx unobtainium hexspeak quatsi"

search_url="${SEARXNG_URL:-http://127.0.0.1:8181}"
engines_raw="${SEARCH_ENGINES:-${DEFAULT_ENGINES}}"
queries_raw="${SEARCH_QUERIES:-${DEFAULT_QUERIES}}"
cap=20

# @function split_list
# Split a comma-separated list into entries, one per line, blanks dropped.
# The comma is the only separator, and only the two ends of an entry are
# trimmed: a query is allowed to hold spaces, and splitting on whitespace as
# well would turn "python 3.12 datetime.fromisoformat format change" into four
# probes of four words instead of one probe of one query.
# Globals:
#   None
# Arguments:
#   $1 - the raw list
# Outputs:
#   One trimmed entry per line, nothing for an empty list
# Returns:
#   0
split_list() {
  local raw="$1" entry
  local IFS=','
  read -ra SPLIT_LIST <<<"${raw}"
  if [ "${#SPLIT_LIST[@]}" -gt 0 ]; then
    for entry in "${SPLIT_LIST[@]}"; do
      # Trim the two ends only, and nothing between them.
      entry="${entry#"${entry%%[![:space:]]*}"}"
      entry="${entry%"${entry##*[![:space:]]}"}"
      [[ -z ${entry} ]] && continue
      printf '%s\n' "${entry}"
    done
  fi
  unset SPLIT_LIST
}

# @function valid_engine
# Succeed when one engine name is a plain token, so it can name a scratch file.
# Globals:
#   None
# Arguments:
#   $1 - candidate engine name
# Outputs:
#   None
# Returns:
#   0 when usable, 1 otherwise
valid_engine() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url)
      [ "$#" -ge 2 ] || usage_error "--url needs a value"
      search_url="$2"
      shift 2
      ;;
    --engines)
      [ "$#" -ge 2 ] || usage_error "--engines needs a comma-separated list"
      engines_raw="$2"
      shift 2
      ;;
    --queries)
      [ "$#" -ge 2 ] || usage_error "--queries needs a comma-separated list"
      queries_raw="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || usage_error "--timeout needs a value in seconds"
      cap="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage_error "unknown argument '$1' (see --help)"
      ;;
  esac
done

search_url="${search_url%/}"
case "${cap}" in '' | *[!0-9]* | 0) usage_error "--timeout needs a whole number of seconds, got '${cap}'" ;; esac

engines=()
while IFS= read -r entry; do
  engines+=("${entry}")
done < <(split_list "${engines_raw}")
queries=()
while IFS= read -r entry; do
  queries+=("${entry}")
done < <(split_list "${queries_raw}")

[ "${#engines[@]}" -gt 0 ] || usage_error "--engines named nothing: pass --engines google,brave"
[ "${#queries[@]}" -gt 0 ] || usage_error '--queries named nothing: pass --queries "who won the world cup"'
for engine in "${engines[@]}"; do
  # An engine name is both the SearXNG `engines=` parameter and the name of
  # the scratch file the pair records land in, so anything but a plain token is
  # a usage error and not a probe.
  valid_engine "${engine}" || usage_error "--engines names engines, not '${engine}'"
done

# ── the sweep ────────────────────────────────────────────────────────────────

if ! has_tool curl; then
  # Nothing can be measured, which is a "not yet" state and not a failure: the
  # same contract spark-verify.sh keeps. Printed through `note` so --json keeps
  # stdout clean, and exit 0 is reserved for "every pair answered".
  section "Search"
  note "curl is not on PATH, so no engine could be probed and nothing was measured"
  summary
  exit 0
fi

if ! has_tool timeout; then
  note "timeout(1) is not on PATH: each probe still carries curl --max-time ${cap}, so a black-holed address still dies at the cap and not at the operating system's much longer patience"
fi

# One scratch directory per run, removed on every exit path, holding one
# `engine.pairs` file per engine. Nothing here is ever written into the repo,
# which is what lets this run inside a Bazel sandbox or a read-only checkout.
work="$(mktemp -d 2>/dev/null || true)"
[ -n "${work}" ] || usage_error "could not create a scratch directory for the probe records"
trap 'rm -rf "${work}"' EXIT

# @function probe_pair
# Probe one engine x query pair and print one record line for it.
# Globals:
#   cap
# Arguments:
#   $1 - base URL; $2 - engine; $3 - query; $4 - scratch file to write
# Outputs:
#   `engine|kind|status|count|seconds|refused` on stdout, where kind is one of
#   ok, empty, 403 or other; refused is yes when a 200 body blames an engine
# Returns:
#   0, always: a pair that does not answer is a result here, not an error
probe_pair() {
  local url="$1" engine="$2" query="$3" sink="$4"
  local answer="" rc=0 status="" seconds="" count="" kind="" refused="no"

  # -G with --data-urlencode keeps this a GET and lets curl do the encoding,
  # so a query holding a space, an apostrophe or a plus sign cannot splice
  # itself into the query string. --noproxy '*' is deliberate: this checks what
  # the search box answers, not what a workstation proxy makes of it.
  #
  # `engines=` (plural) is the one parameter that restricts a query to one
  # engine, and it is sent alone: `engine=` is ignored and `categories=general`
  # re-widens the set to every engine in that category, either of which would
  # have this table report the default engine set four times.
  answer="$(capped_run "${cap}" curl -G -sS --noproxy '*' --max-time "${cap}" \
    -o "${sink}.body" -w '%{http_code} %{time_total}' \
    "${url}/search" \
    --data-urlencode "format=json" \
    --data-urlencode "engines=${engine}" \
    --data-urlencode "q=${query}" \
    2>"${sink}.err")" || rc=$?

  status="${answer%% *}"
  seconds="${answer##* }"
  case "${seconds}" in '' | *[!0-9.]*) seconds="0" ;; esac

  # "Nothing answered" and "answered with nothing" are both results here, and
  # the sweep never aborts on either: one dead engine must not hide the other
  # five. The 403 is split out because it names a config file, not an engine.
  if [ "${rc}" = "124" ] || [ "${rc}" = "143" ]; then
    kind="other"
    status="TIMEOUT"
    seconds="${cap}"
    count="0"
  elif [ -z "${answer}" ]; then
    kind="other"
    status="NOTHING"
    seconds="0"
    count="0"
  elif [ "${status}" = "200" ]; then
    count="$(result_count "${sink}.body")"
    if [ "${count}" != "0" ]; then
      kind="ok"
    else
      kind="empty"
      # A 200 whose envelope blames its own engines ("access denied", "rate
      # limit", "too many requests") is the failure an agent sees as an empty
      # answer, so record it as the answer to the question this script asks.
      if printf '%s' "$(cat "${sink}.body" 2>/dev/null)" |
        grep -q '"unresponsive_engines"[[:space:]]*:[[:space:]]*[^]]' 2>/dev/null; then
        refused="yes"
      fi
    fi
  elif [ "${status}" = "403" ]; then
    kind="403"
    count="0"
  elif [ -z "${status}" ] || [ "${status}" = "000" ]; then
    kind="other"
    status="NOTHING"
    seconds="0"
    count="0"
  else
    kind="other"
    count="0"
  fi

  printf '%s|%s|%s|%s|%s|%s\n' "${engine}" "${kind}" "${status}" "${count}" "${seconds}" "${refused}"
}

# @function result_count
# Count the results in one SearXNG reply body by counting its "url" keys.
# Globals:
#   None
# Arguments:
#   $1 - file holding the reply body, possibly empty
# Outputs:
#   The count on stdout, `0` for a body that is not a results envelope
# Returns:
#   0
result_count() {
  local count="0"
  if [ -s "${1:-}" ]; then
    count="$(grep -o '"url"[[:space:]]*:' "${1}" 2>/dev/null | wc -l | tr -d '[:space:]')"
  fi
  case "${count}" in '' | *[!0-9]*) count="0" ;; esac
  printf '%s' "${count}"
}

# @function record_pair
# Probe one pair and append its record line to that engine's record file.
# Globals:
#   work
# Arguments:
#   $1 - base URL; $2 - engine; $3 - query
# Outputs:
#   One record line, appended to the engine's file and echoed to stderr under
#   --json, so the machine-readable run keeps one line per pair as its proof
# Returns:
#   0, always
record_pair() {
  local line
  line="$(probe_pair "$1" "$2" "$3" "${work}/${2}.pairs.tmp")"
  printf '%s\n' "${line}" >>"${work}/${2}.pairs"
  [ -n "${JSON_MODE:-}" ] && printf '%s\n' "${line}" >&2
  return 0
}

# @function pair_facts
# Print one engine's aggregate fields, space separated and always in this
# order: pairs attempted, answered with results, answered empty, HTTP 403, no
# other answer, slowest seconds, refused count. The engine names itself; that
# is not a field, because the readers already know which engine they asked
# about and a name in a numeric slot is how a sum starts adding up words.
# Read once by both report halves, so the table, --json and the exit code
# cannot disagree about how many pairs answered.
# Globals:
#   work
# Arguments:
#   $1 - engine name
# Outputs:
#   Seven space-separated numbers on stdout, seven zeroes for an engine with
#   no records
# Returns:
#   0
pair_facts() {
  local engine="$1" file="${work}/${1}.pairs"
  local total="0" ok="0" empty="0" forbidden="0" other="0" refused="0" slowest="0"

  if [ ! -s "${file}" ]; then
    printf '%s' "0 0 0 0 0 0 0"
    return 0
  fi

  # One pass, five counters. Counting them together is what makes the
  # reconciliation in --json arithmetic instead of hope: the four kinds
  # partition the line set, so answered+empty+403+other equals the pair count
  # here and nowhere else in the script. A record line is
  # `engine|kind|status|count|seconds|refused`, and these six fields are
  # counted here and read nowhere else.
  local kind status count seconds flag
  while IFS='|' read -r _ kind status _ seconds flag; do
    total=$((total + 1))
    case "${kind}" in
      ok) ok=$((ok + 1)) ;;
      empty) empty=$((empty + 1)) ;;
      403) forbidden=$((forbidden + 1)) ;;
      *) other=$((other + 1)) ;;
    esac
    if [ "${flag}" = "yes" ]; then
      refused=$((refused + 1))
    fi
  done <"${file}"

  # The slowest pair is the largest figure in the seconds column; sort -n
  # keeps the decimals in the right order, which a string sort would not.
  slowest="$(cut -d'|' -f5 "${file}" | sort -n | tail -n 1)"

  printf '%s' "${total} ${ok} ${empty} ${forbidden} ${other} ${slowest:-0} ${refused}"
}

# @function total_facts
# Print the same seven fields for every engine together: the five counters
# summed, slowest the largest figure any engine reported and refused summed.
# print_notes and the exit code read this blob, so the prose, the table and
# the status answer from one measurement.
# Globals:
#   work
# Arguments:
#   $1 - engine list, space separated
# Outputs:
#   The same seven fields on stdout, in the pair_facts order
# Returns:
#   0
total_facts() {
  local engine
  local total="0" ok="0" empty="0" forbidden="0" other="0" refused="0" slowest="0"
  local -a facts=()

  for engine in $1; do
    facts=()
    read -ra facts <<<"$(pair_facts "${engine}")"
    total=$((total + facts[0]))
    ok=$((ok + facts[1]))
    empty=$((empty + facts[2]))
    forbidden=$((forbidden + facts[3]))
    other=$((other + facts[4]))
    slowest="$(printf '%s\n%s\n' "${slowest}" "${facts[5]}" | sort -n | tail -n 1)"
    refused=$((refused + facts[6]))
  done

  printf '%s' "${total} ${ok} ${empty} ${forbidden} ${other} ${slowest} ${refused}"
}

# @function render_table
# Print the per-engine table, the four outcome names spelled out for the
# reader. Each row is one pair_facts blob, so the six printed columns are
# fields one to six of that blob, in that order, with no name in front.
# Globals:
#   work, cap
# Arguments:
#   $1 - engine list, space separated
# Outputs:
#   One heading line and one line per engine on stdout
# Returns:
#   0
render_table() {
  local engine
  local -a facts=()
  printf '%-16s %5s %4s %5s %5s %5s %8s\n' engine pairs ok empty 403 other slowest
  for engine in $1; do
    facts=()
    read -ra facts <<<"$(pair_facts "${engine}")"
    printf '%-16s %5s %4s %5s %5s %5s %8s\n' "${engine}" \
      "${facts[0]}" "${facts[1]}" "${facts[2]}" "${facts[3]}" "${facts[4]}" "${facts[5]}"
  done
}

# @function render_json
# Print the one flat JSON object: five totals and one key pair per engine.
# Globals:
#   work
# Arguments:
#   $1 - engine list, space separated
# Outputs:
#   One line holding the object on stdout; every value is a number, so a
#   reader that wants words reads the table instead
# Returns:
#   0
render_json() {
  local engine
  local -a totals=()
  local -a facts=()
  read -ra totals <<<"$(total_facts "$1")"
  local body="\"pairs_total\":${totals[0]},\"pairs_ok\":${totals[1]},\"pairs_empty\":${totals[2]},\"pairs_403\":${totals[3]},\"pairs_other\":${totals[4]}"

  for engine in $1; do
    facts=()
    read -ra facts <<<"$(pair_facts "${engine}")"
    # <engine>_pairs and <engine>_misses are the first two fields of the same
    # blob the table row for that engine prints, which is what makes the two
    # reports reconcilable: pairs_total is the sum of the per-engine pairs by
    # construction, and so is the four-way split of it printed above.
    body="${body},\"${engine}_pairs\":${facts[0]},\"${engine}_misses\":$((facts[0] - facts[1]))"
  done

  printf '{%s}\n' "${body}"
}

# @function engine_verdict
# Print one engine's verdict word: which kinds of pair failed to answer.
# Globals:
#   work
# Arguments:
#   $1 - engine name
# Outputs:
#   `clean`, `no answer on N pair(s)` when every pair got none, or a mix like
#   `1 empty, 1 HTTP 403, 1 without an answer`
# Returns:
#   0
engine_verdict() {
  local -a facts=()
  read -ra facts <<<"$(pair_facts "$1")"
  local pairs="${facts[0]}" answered="${facts[1]}"
  local empty="${facts[2]}" forbidden="${facts[3]}" other="${facts[4]}"

  if [ "${answered}" = "${pairs}" ]; then
    printf 'clean'
    return 0
  fi
  # Every pair of this engine got nothing back: that is the "is the service
  # up at all" answer, and naming four empty results would blame the engines
  # for what a missing service did.
  if [ "${other}" != "0" ] && [ "${other}" = "${pairs}" ]; then
    printf 'no answer on %s pair(s)' "${pairs}"
    return 0
  fi

  local parts=""
  if [ "${empty}" != "0" ]; then
    parts="${empty} empty"
  fi
  if [ "${forbidden}" != "0" ]; then
    parts="${parts:+${parts}, }${forbidden} HTTP 403"
  fi
  if [ "${other}" != "0" ]; then
    parts="${parts:+${parts}, }${other} without an answer"
  fi
  printf '%s' "${parts}"
}

# `cd` before the probes start: every curl below inherits this directory, so a
# probe that outlives its cap cannot leave a hung process holding a cwd the
# operator cares about, and the script reads no repo file by relative path.
cd "${REPO_ROOT_RESOLVED:-${work}}" || true

# One record file per engine, started empty so a skipped or short engine still
# reports zero pairs instead of an absent file.
for engine in "${engines[@]}"; do
  : >"${work}/${engine}.pairs"
done

if [ -z "${JSON_MODE:-}" ]; then
  log "search-check: ${search_url} with ${#engines[@]} engine(s) x ${#queries[@]} query(ies) = $((${#engines[@]} * ${#queries[@]})) pair(s), ${cap}s per request"
fi

section "Probe"
phase "probe ${search_url}"

for engine in "${engines[@]}"; do
  for query in "${queries[@]}"; do
    record_pair "${search_url}" "${engine}" "${query}"
  done
done

# ── the report ───────────────────────────────────────────────────────────────
# One measurement, printed twice: the table and the JSON object both read the
# same records through pair_facts, so a dashboard and an operator cannot be
# shown two answers.
engine_list="${engines[*]}"

section "Report"
if [ -n "${JSON_MODE:-}" ]; then
  render_json "${engine_list}"
fi

# @function print_notes
# Print the prose an operator acts on: which engines answered, what failed and
# what to do next. Reads the aggregate blob through total_facts, the same one
# the table prints, and routes every line through log/note, so --json keeps
# stdout parseable.
# Globals:
#   work, search_url, cap, JSON_MODE
# Arguments:
#   $1 - engine list, space separated
# Outputs:
#   Prose lines on stderr under --json, on stdout otherwise
# Returns:
#   0
print_notes() {
  local -a facts=()
  local engine
  read -ra facts <<<"$(total_facts "$1")"
  local pairs="${facts[0]}" answered="${facts[1]}" empty="${facts[2]}"
  local forbidden="${facts[3]}" other="${facts[4]}" refused="${facts[6]}"

  log "pairs attempted: ${pairs}, answered with results: ${answered}, answered empty: ${empty}, HTTP 403: ${forbidden}, no answer: ${other}"
  for engine in $1; do
    log "  ${engine}: $(engine_verdict "${engine}")"
  done
  if [ "${forbidden}" != "0" ]; then
    note "the 403s are not an engine fault: searxng/settings.yml has to list json under search.formats, then the service needs a restart. Every engine answers 403 or none does."
  fi
  if [ "${refused}" != "0" ]; then
    note "at least one reply blamed its own engines (SearXNG lists them under unresponsive_engines): the search box is up and the backends are refusing it. That is what an agent sees as an empty search."
  fi
  if [ "${other}" != "0" ] && [ "${other}" = "${pairs}" ]; then
    note "nothing answered anywhere: ${search_url} gave no HTTP reply on any pair. Check that the searxng service is up and publishing 127.0.0.1:8181 before blaming any engine."
  fi
}

if [ -z "${JSON_MODE:-}" ]; then
  printf '\n'
  render_table "${engine_list}"
  printf '\n'
fi
print_notes "${engine_list}"

# One measurement, read a third time: the exit code asks the same question the
# table and the JSON object answered, and it counts the same record lines.
# A non-zero exit that still printed the table is the point: wire this into
# validate.sh or CI and the row that went red is already on the log.
read -ra aggregate <<<"$(total_facts "${engine_list}")"
if [ "${aggregate[1]}" = "${aggregate[0]}" ]; then
  ok "search-check"
fi
summary
if [ "${aggregate[1]}" != "${aggregate[0]}" ]; then
  exit 1
fi
exit 0
