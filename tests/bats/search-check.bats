#!/usr/bin/env bats
#
# ## search-check.bats - hermetic coverage for scripts/search-check.sh.
#
# The probe contract pinned here: one probe per engine x query pair, with a
# multi-word query kept as ONE probe; the four per-pair outcomes (ok, empty,
# 403, other) counted from the reply body and the status line; one aggregate
# field order, shared by pair_facts and total_facts, so the table, --json, the
# per-engine verdicts and the exit code cannot disagree; stdout kept parseable
# under --json; and a usage error answered before anything is probed.
#
# Hermetic by construction. setup() shadows `timeout` and `curl` by prepending
# one private bin/ directory to PATH: search-check.sh shells out to those two
# through capped_run and nothing else that could reach a socket, while the
# coreutils it pipes through (grep, cut, sort, tail, wc, tr) stay the host's.
# A suite that hid those too would test a PATH no operator has ever run on.
# The stub copies live under tests/bats/tool_stubs and travel into the Bazel
# runfiles tree beside this file.
#
# The whole suite skips while scripts/search-check.sh is absent: a suite for a
# script that does not exist yet has no right to fail the gate.
#
# Usage: bazelisk test //tests:bats_search_check_test   (from any cwd)
# Safety: stubs and canned reply bodies only. No live service, no Docker, no
# network.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""
LIB=""
BIN=""
SCRATCH=""

# setup - resolve the checkout, shadow timeout and curl, and lay out this
# test's scratch tree with one scratch file per scratch tree (BATS removes
# BATS_TEST_TMPDIR after each test, so nothing here outlives the test).
# Globals:
#   REPO_ROOT, SCRIPT, LIB, BIN, SCRATCH, STUB_LOG, PATH
# Arguments:
#   None
# Outputs:
#   The private bin/ and the reply bodies it replays
# Returns:
#   0, or a skip when the script, a lib or a stub copy is not available
setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/search-check.sh"
  LIB="${REPO_ROOT}/scripts/lib/common.sh"
  if [ ! -f "${SCRIPT}" ] || [ ! -f "${LIB}" ]; then
    skip "scripts/search-check.sh or its lib is not in the tree"
  fi
  if [ ! -f "${STUB_BIN_DIR}/timeout" ] || [ ! -f "${STUB_BIN_DIR}/curl" ]; then
    skip "the timeout and curl stubs are not in the tree"
  fi

  SCRATCH="$(make_scratch)"
  export STUB_LOG="${SCRATCH}/stub-logs"
  mkdir -p "${STUB_LOG}"
  printf '%s\n' '{"results":[{"url":"http://a"},{"url":"http://b"},{"url":"http://c"}]}' \
    >"${SCRATCH}/three.json"
  BIN="$(stub_bin timeout)"
  write_probe_curl "${BIN}" "${SCRATCH}/three.json" 200 0.42 0 ""
  PATH="$(with_path "${BIN}")"
  export PATH
}

# @function stage_tools
# Copy the named host tools into a private directory, resolved with this test's
# stub directory removed from PATH, so a suite can prove a branch that needs
# one tool MISSING without depending on a host that lacks it.
# Globals:
#   PATH
# Arguments:
#   $1 - destination directory (created)
#   $2 - space-separated tool names
# Outputs:
#   Nothing
# Returns:
#   0 when every tool was staged, 1 when one of them is nowhere to be found
stage_tools() {
  local dir="${1}" names="${2}" name
  mkdir -p "${dir}"
  for name in ${names}; do
    if ! PATH="${PATH#"${BIN}:"}" command -v "${name}" >/dev/null 2>&1; then
      return 1
    fi
    cp "$(PATH="${PATH#"${BIN}:"}" command -v "${name}")" "${dir}/${name}"
    chmod 755 "${dir}/${name}"
  done
  return 0
}

# @function write_probe_curl
# Write the purpose-built curl stand-in for this suite into a directory. The
# replay is data, not code: one default answer plus optional per-engine
# overrides, each `engine:<body>:<status>:<seconds>:<exit code>`, so a sweep can
# answer four engines four different ways in one run. A body given as an
# existing file is read from it; a socket is never opened.
# Globals:
#   STUB_LOG
# Arguments:
#   $1 - directory to write the stand-in into
#   $2 - the default body, or the file holding it (empty for no body at all)
#   $3 - default HTTP status (default 200)
#   $4 - default seconds (default 0.42)
#   $5 - default exit code (default 0)
#   $6 - per-engine overrides, space separated
# Outputs:
#   <dir>/curl and <dir>/timeout, mode 755, and their argv log under STUB_LOG
# Returns:
#   0
write_probe_curl() {
  local dir="${1}"
  local body="${2:-}" status="${3:-200}" seconds="${4:-0.42}" rc="${5:-0}" plan="${6:-}"

  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -u'
    printf 'body=%q\n' "${body}"
    printf 'status=%q\n' "${status}"
    printf 'seconds=%q\n' "${seconds}"
    printf 'rc=%q\n' "${rc}"
    printf 'plan=%q\n' "${plan}"
    cat <<'PROBE_CURL'
# Purpose-built curl stand-in for tests/bats/search-check.bats: replays a
# canned reply, never a socket and never a real wait.
set -u

if [ -n "${STUB_LOG:-}" ]; then printf '%s\n' "curl $*" >>"${STUB_LOG}/curl.log"; fi

argv="$*"
answer_body="${body}"
answer_status="${status}"
answer_seconds="${seconds}"
answer_rc="${rc}"

for spec in ${plan}; do
  engine="${spec%%:*}"
  rest="${spec#*:}"
  case "${argv}" in
    *"engines=${engine} "*)
      answer_body="${rest%%:*}"
      rest="${rest#*:}"
      answer_status="${rest%%:*}"
      rest="${rest#*:}"
      answer_seconds="${rest%%:*}"
      rest="${rest#*:}"
      answer_rc="${rest#*:}"
      break
      ;;
  esac
done

if [ -n "${answer_body}" ] && [ -f "${answer_body}" ]; then
  answer_body="$(cat "${answer_body}")"
fi

sink=""
previous=""
for argument in "$@"; do
  if [ "${previous}" = "-o" ]; then
    sink="${argument}"
  fi
  previous="${argument}"
done

if [ -n "${sink}" ]; then
  printf '%s' "${answer_body}" >"${sink}"
fi
printf '%s %s' "${answer_status}" "${answer_seconds}"
exit "${answer_rc}"
PROBE_CURL
  } >"${dir}/curl"
  chmod 755 "${dir}/curl"
}

@test "search-check: --help answers with the usage block and probes nothing" {
  run --separate-stderr bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "usage names its own flags" 'usage: bazelisk run //scripts:search-check -- \[--url URL\]' "${output}"
  assert_match "usage states the exit codes" '2 =$' "${output}"
  [ "$(stub_log_count curl)" -eq 0 ]
}

@test "search-check: a usage error is answered before anything is probed" {
  # Every case here is a typo, not a result: an unknown flag, a flag that eats
  # the next flag as its value, a cap that is not a number, and a list that
  # names nothing. All four must answer 2 and probe nothing.
  run --separate-stderr bash "${SCRIPT}" --bogus
  [ "${status}" -eq 2 ]
  assert_match "unknown flag named" 'unknown argument' "${stderr}"

  run --separate-stderr bash "${SCRIPT}" --timeout
  [ "${status}" -eq 2 ]

  run --separate-stderr bash "${SCRIPT}" --timeout abc
  [ "${status}" -eq 2 ]

  run --separate-stderr bash "${SCRIPT}" --queries ',,'
  [ "${status}" -eq 2 ]
  assert_match "empty list rejected" 'named nothing' "${stderr}"

  run --separate-stderr bash "${SCRIPT}" --engines 'a b' --queries 'alpha beta gamma'
  [ "${status}" -eq 2 ]
  assert_match "engine list split on commas only" 'names engines, not' "${stderr}"

  [ "$(stub_log_count curl)" -eq 0 ]
}

@test "search-check: one multi-word query is one probe, not one probe per word" {
  run --separate-stderr bash "${SCRIPT}" --url http://127.0.0.1:8181 --engines wikipedia --queries 'alpha beta gamma' --timeout 2
  [ "${status}" -eq 0 ]
  # The count is the whole point: three words would be three probes if the
  # splitter split on spaces, and the query an agent sends is a phrase.
  [ "$(stub_log_count curl)" -eq 1 ]
  assert_match "query sent whole" 'q=alpha beta gamma' "$(stub_log curl)"
  assert_match "one pair counted" 'pairs attempted: 1' "${output}"
  assert_match "one engine x one query counted" '1 engine\(s\) x 1 query\(ies\) = 1 pair\(s\)' "${output}"
}

@test "search-check: the shipped defaults probe eighteen pairs" {
  # Six engines x three queries. Seventeen probes would mean the default query
  # trio was shredded into words, which is the bug this pins shut.
  run --separate-stderr bash "${SCRIPT}" --url http://127.0.0.1:8181 --timeout 2
  [ "${status}" -eq 0 ]
  [ "$(stub_log_count curl)" -eq 18 ]
  assert_match "six engines, three queries" '6 engine\(s\) x 3 query\(ies\) = 18 pair' "${output}"
  assert_match "first default query whole" 'q=what language was the linux kernel written in' "$(stub_log curl)"
  assert_match "second default query whole" 'q=python 3.12 datetime.fromisoformat format change' "$(stub_log curl)"
  assert_match "third default query whole" 'q=zzyzx unobtainium hexspeak quatsi' "$(stub_log curl)"
}

@test "search-check: two comma-separated queries are two probes" {
  run --separate-stderr bash "${SCRIPT}" --url http://127.0.0.1:8181 --engines wikipedia --queries 'alpha beta gamma,brave search' --timeout 2
  [ "${status}" -eq 0 ]
  [ "$(stub_log_count curl)" -eq 2 ]
  assert_match "phrase kept as one probe" 'q=alpha beta gamma' "$(stub_log curl)"
  assert_match "second query kept whole" 'q=brave search' "$(stub_log curl)"
}

@test "search-check: no curl on PATH is a not-yet answer, printed and exit 0" {
  # require_tool's convention: nothing could be measured, which is not a
  # failure. The private bin/ holds every other tool the script shells out to
  # and no curl, so this proves the branch without needing a host without curl.
  local plain="${SCRATCH}/plain"
  if ! stage_tools "${plain}" "bash dirname cat mktemp grep wc tr cut sort tail rm"; then
    skip "the host tools the probe path shells out to are not all on PATH"
  fi

  # Invoke this suite's bash by absolute path: staging `bash` can copy a
  # 3.2 /bin/bash that cannot parse the script, and `env PATH=... bash` would
  # then pick that copy.
  run --separate-stderr env PATH="${plain}" "${BASH}" "${SCRIPT}" --url http://127.0.0.1:8181 --engines wikipedia --queries 'alpha beta gamma' --timeout 2
  [ "${status}" -eq 0 ]
  assert_match "reason printed" 'curl is not on PATH' "${output}"
  assert_not_match "nothing probed" 'search-check: http' "${output}"
}

@test "search-check: every probe names one engine and no category" {
  # `engine=` (singular) is ignored by SearXNG and `categories=general`
  # re-widens the query to every engine in that category. Either one leaves the
  # table printing the same default engine set four times, and a table that
  # cannot say which engine answered is the table this script exists to avoid.
  run --separate-stderr bash "${SCRIPT}" --url http://127.0.0.1:8181 --engines wikipedia,brave --queries 'alpha beta gamma' --timeout 2
  [ "${status}" -eq 0 ]
  [ "$(stub_log_count curl)" -eq 2 ]
  assert_match "first engine named" 'engines=wikipedia' "$(stub_log curl)"
  assert_match "second engine named" 'engines=brave' "$(stub_log curl)"
  assert_not_match "no category filter sent" 'categories=' "$(stub_log curl)"
}

@test "search-check: the four outcomes stay four distinct rows" {
  # wikipedia answers, brave answers empty, stackoverflow answers 403 and
  # github does not answer at all. Read as one sweep the four shapes must land
  # in four different columns, or the table cannot tell "search is down" apart
  # from "search is down for one engine".
  printf '%s\n' '{"results":[{"url":"http://a"},{"url":"http://b"},{"url":"http://c"}]}' >"${SCRATCH}/three.json"
  printf '%s\n' '{"results":[]}' >"${SCRATCH}/empty.json"
  printf '%s\n' '{"error":"format not allowed"}' >"${SCRATCH}/403.json"
  write_probe_curl "${BIN}" "${SCRATCH}/three.json" 200 0.42 0 \
    "brave:${SCRATCH}/empty.json:200:0.42:0 stackoverflow:${SCRATCH}/403.json:403:0.42:0 github::000:0.000129:7"

  run --separate-stderr bash "${SCRIPT}" --url http://127.0.0.1:8181 --engines wikipedia,brave,stackoverflow,github --queries 'alpha beta gamma' --timeout 2
  [ "${status}" -eq 1 ]
  assert_match "results counted" '^wikipedia +1 +1 +0 +0 +0 +0\.42' "${output}"
  assert_match "empty counted" '^brave +1 +0 +1 +0 +0 +0\.42' "${output}"
  assert_match "403 counted as 403" '^stackoverflow +1 +0 +0 +1 +0 +0\.42' "${output}"
  assert_match "no answer counted" '^github +1 +0 +0 +0 +1' "${output}"
  assert_match "the four kinds add up to the pair count" 'pairs attempted: 4, answered with results: 1, answered empty: 1, HTTP 403: 1, no answer: 1' "${output}"
  assert_match "403 blamed on the config file" 'not an engine fault' "${output}"
}

@test "search-check: one engine that cannot be reached is not blamed on the engine" {
  write_probe_curl "${BIN}" "" 000 0.000129 7 ""
  run --separate-stderr bash "${SCRIPT}" --url http://127.0.0.1:8181 --engines wikipedia,brave --queries 'alpha beta gamma' --timeout 2
  [ "${status}" -eq 1 ]
  assert_match "refused counted per engine" 'wikipedia: no answer on 1 pair' "${output}"
  assert_match "refused counted in the totals" 'no answer: 2' "${output}"
  assert_match "a dead service named as the cause" 'nothing answered anywhere' "${output}"
  assert_not_match "no engine blamed for a dead service" 'not an engine fault' "${output}"
}

@test "search-check: a reply that blames its engines is counted and said out loud" {
  printf '%s\n' '{"results":[],"unresponsive_engines":{"brave":"error"}}' >"${SCRATCH}/blame.json"
  write_probe_curl "${BIN}" "${SCRATCH}/blame.json" 200 0.42 0 ""
  run --separate-stderr bash "${SCRIPT}" --url http://127.0.0.1:8181 --engines brave --queries 'alpha beta gamma' --timeout 2
  [ "${status}" -eq 1 ]
  assert_match "blame counted as an empty answer" 'brave +1 +0 +1' "${output}"
  assert_match "blame named" 'blamed its own engines' "${output}"
}

@test "search-check: --json and the table are one measurement, printed twice" {
  printf '%s\n' '{"results":[{"url":"http://a"},{"url":"http://b"},{"url":"http://c"}]}' >"${SCRATCH}/three.json"
  write_probe_curl "${BIN}" "${SCRATCH}/three.json" 200 0.42 0 ""

  run --separate-stderr bash "${SCRIPT}" --json --url http://127.0.0.1:8181 --engines wikipedia,brave --queries 'alpha beta gamma' --timeout 2
  [ "${status}" -eq 0 ]
  assert_match "one flat object on stdout" '^\{"pairs_total":2,"pairs_ok":2,"pairs_empty":0,"pairs_403":0,"pairs_other":0,"wikipedia_pairs":1,"wikipedia_misses":0,"brave_pairs":1,"brave_misses":0\}$' "${output}"
  assert_not_match "table kept off stdout" 'engine +pairs' "${output}"
  assert_match "records kept off stdout" 'wikipedia\|ok\|200\|3\|0\.42\|no' "${stderr}"

  local python
  python="$(real_bin python3)"
  if [ -z "${python}" ]; then
    skip "python3 is not on PATH, so there is nothing to parse the object with"
  fi
  printf '%s\n' "${output}" | "${python}" -c 'import json,sys; json.load(sys.stdin)'
}

@test "search-check: one capped probe does not hold the sweep hostage" {
  printf '%s\n' '{"results":[]}' >"${SCRATCH}/empty.json"
  write_probe_curl "${BIN}" "${SCRATCH}/empty.json" 200 9.90 124 ""
  run --separate-stderr bash "${SCRIPT}" --url http://127.0.0.1:8181 --engines wikipedia,brave --queries 'alpha beta gamma' --timeout 2
  [ "${status}" -eq 1 ]
  # timeout(1) wrapping curl, and curl's own --max-time, both carry the cap.
  assert_match "capped by timeout(1)" '^timeout 2 curl' "$(stub_log timeout)"
  [ "$(stub_log_count timeout)" -eq 2 ]
  assert_match "capped by curl" -- '--max-time 2' "$(stub_log curl)"
  assert_match "cap counted as a result, not a crash" 'wikipedia +1 +0 +0 +0 +1 +2' "${output}"
  assert_match "both pairs counted as no answer" 'no answer: 2' "${output}"

  # The same cap read back as a record line under --json, which is where the
  # per-pair records are printed: a timed-out pair is one row of the sweep.
  run --separate-stderr bash "${SCRIPT}" --json --url http://127.0.0.1:8181 --engines wikipedia,brave --queries 'alpha beta gamma' --timeout 2
  [ "${status}" -eq 1 ]
  assert_match "record line names the timeout" 'wikipedia\|other\|TIMEOUT\|0\|2\|no' "${stderr}"
  assert_match "the object counts it too" '"pairs_other":2' "${output}"
}

@test "search-check: split_list splits on commas and trims the two ends" {
  # The comma is the only separator, and the two ends of an entry are the only
  # things trimmed: a query is allowed to hold spaces, and splitting those too
  # would turn one phrase into four probes of four words.
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" split_list

  assert_eq "two names stay two entries" "google
brave" "$(split_list 'google,brave')"
  assert_eq "a phrase stays one entry" "python 3.12 datetime.fromisoformat format change" \
    "$(split_list 'python 3.12 datetime.fromisoformat format change')"
  assert_eq "only the two ends are trimmed" "brave
duckduckgo" "$(split_list ' brave , duckduckgo ')"
  assert_eq "a list of blanks names nothing" "" "$(split_list ',,')"
  assert_eq "an empty list names nothing" "" "$(split_list '')"
}

@test "search-check: valid_engine accepts only a name that can name a file" {
  # An engine name is both the SearXNG `engines=` parameter and the name of
  # the scratch file that engine's records land in, so anything but a plain
  # token has to be refused before the sweep starts.
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" valid_engine

  valid_engine wikipedia
  valid_engine google-news
  valid_engine 'brave.scrape'
  valid_engine 'a_b_c'
  if valid_engine 'a b'; then
    fail "a name with a space cannot name a probe file"
  fi
  if valid_engine 'brave;rm -rf'; then
    fail "a name with punctuation is not one engine"
  fi
  if valid_engine ''; then
    fail "an empty name is not an engine"
  fi
}

@test "search-check: usage_error prints the complaint and the usage block, then exits 2" {
  # The pair of them is the contract: a typo has to be answered with the flag
  # list, and answered before the first probe, so it can never be read as a
  # result. Run in a subshell because the helper exits rather than returns.
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" usage
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" usage_error

  run --separate-stderr usage_error '--timeout needs a whole number of seconds, got abc'
  [ "${status}" -eq 2 ]
  assert_match "the complaint names the flag" 'timeout needs a whole number' "${stderr}"
  assert_match "the usage block comes with it" 'usage: bazelisk run //scripts:search-check -- \[--url URL\]' "${output}"
}

@test "search-check: pair_facts and total_facts read one field order" {
  # The aggregate blob is seven fields with no engine name in front, because
  # every reader already knows which engine it is asking about, and a name in a
  # numeric slot is how a sum starts adding up words.
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" pair_facts
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" total_facts
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" engine_verdict
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" print_notes
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" render_table
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" render_json

  local work="${SCRATCH}/facts"
  mkdir -p "${work}"

  printf '%s\n' 'wikipedia|empty|200|0|2.500000|no' 'wikipedia|other|000|0|0.000129|no' \
    >"${work}/wikipedia.pairs"
  assert_eq "counted from the columns" "2 0 1 0 1 2.500000 0" "$(pair_facts wikipedia)"

  printf '%s\n' 'brave|ok|200|3|1.000000|yes' 'brave|403|403|0|0.500000|no' \
    >"${work}/brave.pairs"
  assert_eq "refused counted, not read as seconds" "2 1 0 1 0 1.000000 1" "$(pair_facts brave)"
  assert_eq "verdict names what failed" "1 HTTP 403" "$(engine_verdict brave)"

  # An engine nobody probed is still a row, and still seven fields.
  : >"${work}/empty.pairs"
  assert_eq "no records is seven zeroes" "0 0 0 0 0 0 0" "$(pair_facts empty)"

  # The same seven fields summed, and the prose that reads them.
  assert_eq "totals from the same fields" "4 1 1 1 1 2.500000 1" "$(total_facts "wikipedia brave empty")"
  local notes
  notes="$(print_notes "wikipedia brave empty")"
  assert_match "totals prose agrees with the blob" 'pairs attempted: 4, answered with results: 1, answered empty: 1, HTTP 403: 1, no answer: 1' "${notes}"
  assert_match "blame note fired from the count" 'blamed its own engines' "${notes}"
  assert_eq "an engine with two kinds of miss names both" "1 empty, 1 without an answer" "$(engine_verdict wikipedia)"

  # Table and --json print the same fields per engine, from the same blob.
  local table json
  table="$(render_table "wikipedia brave empty")"
  assert_match "table reads the fields" 'brave +2 +1 +0 +1 +0 +1[.]000000' "${table}"
  json="$(render_json "wikipedia brave empty")"
  assert_eq "json totals are the sum" '{"pairs_total":4,"pairs_ok":1,"pairs_empty":1,"pairs_403":1,"pairs_other":1,"wikipedia_pairs":2,"wikipedia_misses":2,"brave_pairs":2,"brave_misses":1,"empty_pairs":0,"empty_misses":0}' "${json}"
}

@test "search-check: one record line, written where it can be read back" {
  # engine|kind|status|count|seconds|refused, six fields, and the sink file
  # that carries the reply body is rebuilt for every pair instead of trusted
  # to hold the last one.
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" probe_pair
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" result_count
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" record_pair
  local work="${SCRATCH}/records"
  mkdir -p "${work}"
  local cap=2

  printf '%s\n' '{"results":[{"url":"http://a"},{"url":"http://b"},{"url":"http://c"}]}' \
    >"${work}/body.json"
  assert_eq "three url keys are three results" "3" "$(result_count "${work}/body.json")"
  printf '%s\n' '{"results":[]}' >"${work}/none.json"
  assert_eq "an envelope with no url key is zero" "0" "$(result_count "${work}/none.json")"
  assert_eq "a missing file is zero" "0" "$(result_count "${work}/missing")"

  local line
  line="$(probe_pair "http://127.0.0.1:8181" "brave" "alpha beta gamma" "${work}/brave.pairs.tmp")"
  assert_eq "one record line, six fields" "brave|ok|200|3|0.42|no" "${line}"

  record_pair "http://127.0.0.1:8181" "brave" "alpha beta gamma"
  record_pair "http://127.0.0.1:8181" "brave" "brave search"
  assert_eq "one line per pair, appended" "2" "$(wc -l <"${work}/brave.pairs" | tr -d '[:space:]')"
  assert_eq "second query kept whole" "brave|ok|200|3|0.42|no" "$(tail -n 1 "${work}/brave.pairs")"
  assert_match "GET keeps the query encoded" 'q=brave search' "$(stub_log curl)"
}

@test "search-check: the probe path is found wherever the script is run from" {
  # resolve_repo_root probes for a marker instead of trusting the cwd, and
  # find_lib probes for the helper beside it: under `bazel test` the cwd is a
  # copy of the tree, and a run from a foreign cwd has no helper beside the
  # script at all.
  # shellcheck source=/dev/null
  source "${LIB}"
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" resolve_repo_root
  # shellcheck source=/dev/null
  load_shell_function "${SCRIPT}" find_lib

  local nowhere="${SCRATCH}/nowhere"
  mkdir -p "${nowhere}"
  # Shadowed, not exported: these three are what the helper probes, and a
  # leftover value from the harness would answer the question for it.
  local REPO_ROOT=""
  local GITHUB_WORKSPACE=""
  local SELF_DIR="${nowhere}"
  cd "${nowhere}"
  run --separate-stderr resolve_repo_root
  [ "${status}" -eq 5 ]
  assert_match "an unresolvable root is reported" 'unresolvable repo root' "${stderr}"

  # A runfiles copy of the tree holds a COPY of docker-compose.yml, so the cwd
  # probe still works there; a run from a foreign cwd has neither the marker
  # nor a helper beside the script, and that is what the SELF_DIR probe is for.
  assert_eq "a helper with no home is reported, not guessed" "" "$(find_lib common.sh "")"

  local copy="${SCRATCH}/copy"
  mkdir -p "${copy}/scripts/lib"
  cp "${LIB}" "${copy}/scripts/lib/common.sh"
  SELF_DIR="${copy}/scripts"
  assert_eq "helper found beside the script, wherever it sits" \
    "${copy}/scripts/lib/common.sh" "$(find_lib common.sh "")"
}

@test "search-check: the sweep leaves no probe files behind" {
  # One scratch directory per run, removed on every exit path, and nothing
  # written into the checkout: that is what lets this run in a Bazel sandbox
  # and beside a read-only working tree.
  local tmp="${SCRATCH}/tmp"
  mkdir -p "${tmp}"
  run --separate-stderr env TMPDIR="${tmp}" bash "${SCRIPT}" --url http://127.0.0.1:8181 --engines wikipedia --queries 'alpha beta gamma' --timeout 2
  [ "${status}" -eq 0 ]
  [ -z "$(find "${tmp}" -mindepth 1)" ]

  # A run whose mktemp cannot create the scratch directory still exits with
  # the documented usage error and no partial table. TMPDIR tricks are not
  # enough: BSD mktemp falls back to /tmp when TMPDIR is missing, a file, or
  # unwritable, so the probe is a mktemp on PATH that always fails.
  local failbin="${SCRATCH}/fail-mktemp"
  mkdir -p "${failbin}"
  printf '%s\n' '#!/bin/sh' 'exit 1' >"${failbin}/mktemp"
  chmod 755 "${failbin}/mktemp"
  run --separate-stderr env PATH="${failbin}:${PATH}" bash "${SCRIPT}" --engines wikipedia
  [ "${status}" -eq 2 ]
  assert_match "scratch failure is a usage error" 'scratch directory' "${stderr}"
}
