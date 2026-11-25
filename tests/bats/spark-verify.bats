#!/usr/bin/env bats
#
# ## spark-verify.bats - hermetic coverage for scripts/spark-verify.sh.
#
# The entry script is the fleet's drift check; scripts/lib/probes/spark-verify.sh
# (the remote half) has its own suite in probes.bats, and the pure helpers this
# file also exercises live beside these cases in entry-fns.bats. What is pinned
# here is the policy the operator reads: a box that answers nothing is a DOWN
# verdict that fails the run unless --expect-down or --tolerate-unreachable
# accounts for it; a host list that is nothing but the shipped spark-<n>.lan
# placeholders stays a not-yet skip at exit 0; the ssh session's own first
# complaint is what gets quoted; --json keeps stdout to one object per host; and
# a bad flag is refused before any probe leaves the box.
#
# It also pins what travels to the far side in the assignment block the ssh
# session carries: the recipe-probe flag has to arrive spelled the way the
# remote gate reads it, and the 195k needle is scheduled only on a box whose
# /health reports nothing running -- unless --needle says otherwise.
#
# Usage: bazelisk test //tests:bats_spark_verify_test   (from any cwd)
# Safety: curl, ssh and timeout resolve through tests/bats/tool_stubs and the
# CLI runs inside a scratch checkout, so no host is dialled, no ssh session is
# opened, and sparks/ output lands under the per-test tree.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/spark-verify.sh"
  [[ -f ${SCRIPT} ]] || skip "scripts/spark-verify.sh is not in the tree"
  use_stubs curl ssh timeout
}

# scratch_checkout - a directory resolve_checkout accepts as the checkout, with
# the one repo file the entry script cats by path (the remote probe body).
scratch_checkout() {
  local scratch
  scratch="$(make_scratch)"
  mkdir -p "${scratch}/scripts/lib/probes"
  printf 'services: {}\n' >"${scratch}/docker-compose.yml"
  cp "${REPO_ROOT}/scripts/lib/probes/spark-verify.sh" "${scratch}/scripts/lib/probes/spark-verify.sh"
  printf '%s' "${scratch}"
}

@test "spark-verify: a box that answers nothing is DOWN and fails the run" {
  local scratch
  scratch="$(scratch_checkout)"
  # The curl stub's default answer is an empty body with exit 22 (nothing
  # answered) and the ssh stub refuses with one stderr line, which is what the
  # caller quotes through first_line. 10.0.0.1 is an address somebody wrote
  # down, so an unanswered probe there is a box the proxy is routing around,
  # not a "not yet" state, and the run has to say so in its exit code.
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --no-tests 10.0.0.1
  [ "${status}" -eq 1 ]
  assert_match "the host is named as a section" '^== host 10\.0\.0\.1 ==$' "${output}"
  assert_match "the http probe is announced" '^-> probing http://10\.0\.0\.1:8888$' "${output}"
  assert_match "ssh's own first line is quoted as the note" 'ssh: stub failure' "${output}"
  assert_match "the per-host verdict reads DOWN" '10\.0\.0\.1 .*DOWN \(nothing answered' "${output}"
  assert_match "the FAIL line names the count and the box" 'FAIL: 1 box\(es\) answered nothing on :8888 and are DOWN \(10\.0\.0\.1\)' "${output}"
  assert_match "the note names the health filter that pulls a dead box out" 'enable_health_check_routing in general_settings' "${output}"
  assert_match "the note says cooldown cannot do it" 'APIConnectionError' "${output}"
  assert_match "the all-down summary" 'summary: no Spark answered on :8888' "${output}"
  assert_match "the note calls the whole fleet down" 'every box in the fleet is DOWN' "${output}"
  assert_contains_file "the per-host verdict was written" "${scratch}/sparks/10.0.0.1.jsonl" '"verdict":"DOWN"'
  [[ "$(stub_log_last curl)" == "curl -fsS -m 5 http://10.0.0.1:8888/health" ]]
}

@test "spark-verify: --json keeps stdout to one object per host" {
  local scratch
  scratch="$(scratch_checkout)"
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --json --no-tests 10.0.0.1
  [ "${status}" -eq 1 ]
  [ "$(printf '%s\n' "${output}" | wc -l | tr -d ' ')" -eq 1 ]
  assert_match "one parseable object" '^\{"host":"10\.0\.0\.1","reachable":false,"verdict":"DOWN"' "${output}"
  assert_match "the object carries the excuse flag too" '"expected_down":false' "${output}"
  # The commentary is what --json moves to stderr, so the same lines are still
  # there, just off stdout.
  assert_match "the commentary moved to stderr" '^== host 10\.0\.0\.1 ==$' "${stderr}"
  assert_contains_file "the object was written too" "${scratch}/sparks/10.0.0.1.jsonl" '"reachable":false'
}

@test "spark-verify: first_line prints one line and an all-blank block does not abort" {
  # pipefail is the reason this helper exists at all: a grep that matches
  # nothing exits 1, and every caller is an assignment under `set -e`.
  set -o pipefail
  load_shell_function "${SCRIPT}" first_line
  local block
  block="$(printf '\n   \nssh: connect to host 10.0.0.1 port 22: refused\n\nsecond line\n')"
  run first_line "${block}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "ssh: connect to host 10.0.0.1 port 22: refused" ]

  run first_line "$(printf '\n \n\t\n')"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  run first_line ""
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "spark-verify: an unknown option is refused before any probe leaves the box" {
  local scratch
  scratch="$(scratch_checkout)"
  run --separate-stderr env REPO_ROOT="${scratch}" bash "${SCRIPT}" --bogus
  [ "${status}" -eq 1 ]
  assert_match "the flag is named" 'unknown option .--bogus.' "${stderr}"
  assert_match "the pointer to help is there" 'see --help' "${stderr}"
  [ "$(stub_log_count curl)" -eq 0 ]
  [ "$(stub_log_count ssh)" -eq 0 ]
  [ ! -e "${scratch}/sparks" ]
}

# The body the curl stub answers /v1/models and /health with, shaped like the TensorFold
# server's and parameterised on the one figure the needle gate reads.
spark_body() {
  printf '{"models":["qwen3.8-flash-next"],"streams": {"max": 5}, "requests_running": %s}' "$1"
}

# The body a box that satisfies the fleet contract answers with: the exact served id the
# entry script compares, five streams, and the running count. spark_body above is
# deliberately the wrong spelling, which is enough for the probes that read only
# requests_running and wrong for a test that needs a box to pass.
spark_ok_body() {
  printf '{"data":[{"id":"Qwen3.8-Flash-Next"}],"streams": {"max": 5}, "requests_running": %s}' "$1"
}

# The assignment block the entry script prepends to the remote probe body, decoded out of
# the base64 handed to the ssh stub. That block is the entire contract with the far side:
# the remote gates read nothing else, so this is where a mistranslation shows up.
transferred_assignments() {
  local line payload
  line="$(stub_log_last ssh)"
  [ -n "${line}" ] || return 1
  payload="$(printf '%s' "${line}" | sed -E "s/.*printf '%s' '([^']*)'.*/\1/")"
  [ "${payload}" != "${line}" ] || return 1
  printf '%s' "${payload}" | base64 -d | head -n 7
}

@test "spark-verify: the recipe probes are really asked for on the far side" {
  # The remote half gates on the literal `yes`. Handing it the entry script's own 1 read
  # as "not asked for", so toolcheck, the needle, visioncheck and bench were skipped on
  # every invocation -- --tests included -- while the run still printed a clean verdict.
  local scratch assignments
  scratch="$(scratch_checkout)"

  run --separate-stderr env REPO_ROOT="${scratch}" STUB_CURL_OUT="$(spark_body 0)" \
    bash "${SCRIPT}" 10.0.0.1
  assignments="$(transferred_assignments)"
  assert_match "the asked-for case arms the probe block" 'RUN_TESTS="yes"' "${assignments}"

  run --separate-stderr env REPO_ROOT="${scratch}" STUB_CURL_OUT="$(spark_body 0)" \
    bash "${SCRIPT}" --no-tests 10.0.0.1
  assignments="$(transferred_assignments)"
  assert_match "the declined case disarms it" 'RUN_TESTS=""' "${assignments}"
}

@test "spark-verify: the 195k needle is scheduled only on a box with nothing running" {
  # The needle prefills 195k tokens the server has never seen, which evicts the warm
  # prompt state a live conversation is riding on. The gate reads requests_running off
  # the same /health the dashboard reads.
  local scratch assignments
  scratch="$(scratch_checkout)"

  run --separate-stderr env REPO_ROOT="${scratch}" STUB_CURL_OUT="$(spark_body 3)" \
    bash "${SCRIPT}" 10.0.0.1
  assignments="$(transferred_assignments)"
  assert_match "a busy box is not handed the needle" 'NEEDLE_WANTED=""' "${assignments}"
  assert_match "the cheap probes still run there" 'RUN_TESTS="yes"' "${assignments}"

  run --separate-stderr env REPO_ROOT="${scratch}" STUB_CURL_OUT="$(spark_body 0)" \
    bash "${SCRIPT}" 10.0.0.1
  assignments="$(transferred_assignments)"
  assert_match "a quiet box gets the window proof" 'NEEDLE_WANTED="yes"' "${assignments}"
}

@test "spark-verify: --needle schedules the window proof even on a busy box" {
  local scratch assignments
  scratch="$(scratch_checkout)"
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_CURL_OUT="$(spark_body 3)" \
    bash "${SCRIPT}" --needle 10.0.0.1
  assignments="$(transferred_assignments)"
  assert_not_match "the flag was not refused" 'unknown option' "${stderr}"
  assert_match "the operator's word wins over the busy gate" 'NEEDLE_WANTED="yes"' "${assignments}"
}

@test "spark-verify: a .env that names a box only by SPARKn_OLLAMA_URL warns about it" {
  # The key stopped feeding the host list, so a box named only there left the fleet in
  # silence. The advisory names the key and the host it lost; the fleet, the verdict and
  # the exit code stay the ones the surviving keys give, which is what the two runs
  # below differ on.
  local scratch
  scratch="$(scratch_checkout)"

  printf '%s\n' 'SPARK2_OLLAMA_URL=http://10.9.8.6:11434' >"${scratch}/.env"
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --no-tests
  [ "${status}" -eq 0 ]
  assert_match "the stale key and its host are named" 'warning: SPARK2_OLLAMA_URL=http://10\.9\.8\.6:11434 in \.env is no longer read, so 10\.9\.8\.6 is not in the fleet' "${output}"
  assert_match "that box is not among the hosts it checks" 'checking the placeholder trio spark-1\.lan spark-2\.lan spark-3\.lan' "${output}"

  printf '%s\n' 'SPARK2_OLLAMA_URL=http://10.9.8.6:11434' 'SPARK2_HOST=10.9.8.6' >"${scratch}/.env"
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --no-tests
  # The advisory itself changes nothing; the exit code differs only because the box now
  # rides the fleet, and a real address that answers nothing is DOWN (pinned above).
  [ "${status}" -eq 1 ]
  assert_match "the same box now rides the fleet" 'in \.env: 10\.9\.8\.6' "${output}"
  assert_not_match "a host the fleet already names is not warned about" 'SPARK2_OLLAMA_URL=' "${output}"
}

@test "spark-verify: an unparseable SPARKn_OLLAMA_URL warns about nothing" {
  # canonical_url turns these into an empty or junk host, and a warning that names no
  # host is noise the operator cannot act on. The same guard derive_spark_hosts applies
  # to its own keys has to apply here too, so the run stays silent about the value.
  local scratch
  scratch="$(scratch_checkout)"

  printf '%s\n' 'SPARK1_OLLAMA_URL=://' 'SPARK2_OLLAMA_URL=/foo' >"${scratch}/.env"
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --no-tests
  [ "${status}" -eq 0 ]
  assert_not_match "no warning is printed for a host it cannot name" 'is no longer read' "${output}"
}

@test "spark-verify: --expect-down excuses a box the operator took out" {
  # The escape for a deliberate outage. The box is still probed, still printed,
  # still counted unreachable -- it just cannot fail the run, and the summary says
  # in so many words that the green came from a flag and not from the fleet.
  local scratch
  scratch="$(scratch_checkout)"
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --no-tests --expect-down 10.0.0.1 10.0.0.1
  [ "${status}" -eq 0 ]
  assert_match "the verdict detail names the flag" 'named with --expect-down' "${output}"
  assert_match "the summary says the outage was accounted for" 'accounted for by --expect-down' "${output}"
  assert_not_match "no down verdict is printed" 'FAIL: .*are DOWN' "${output}"
  assert_contains_file "the box is still reported, as a skip" "${scratch}/sparks/10.0.0.1.jsonl" '"verdict":"SKIP"'
  assert_contains_file "and the object says it was expected down" "${scratch}/sparks/10.0.0.1.jsonl" '"expected_down":true'
}

@test "spark-verify: --expect-down on a box that answered says it is back" {
  # The excuse going stale is the dangerous direction: a run that trusts it would
  # ride a dead box. Advisory, and the box is still judged on its answer.
  local scratch
  scratch="$(scratch_checkout)"
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    STUB_CURL_OUT="$(spark_ok_body 0)" \
    bash "${SCRIPT}" --no-tests --expect-down 10.0.0.1 10.0.0.1
  [ "${status}" -eq 0 ]
  assert_match "the stale excuse is warned about" 'warning: 10\.0\.0\.1 was named with --expect-down but answered on :8888' "${output}"
  assert_contains_file "the box is judged on its answer, not the flag" "${scratch}/sparks/10.0.0.1.jsonl" '"verdict":"OK"'
}

@test "spark-verify: --expect-down naming no host in the fleet excuses nothing" {
  # A typo in the flag must not read as "accounted for": the operator believes the
  # outage is covered while the dead box still fails the run, so it says so.
  local scratch
  scratch="$(scratch_checkout)"
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --no-tests --expect-down 10.9.9.9 10.0.0.1
  [ "${status}" -eq 1 ]
  assert_match "the name that matched nothing is reported" 'warning: --expect-down 10\.9\.9\.9 names no host in this fleet' "${output}"
  assert_match "the real box still reads DOWN" '10\.0\.0\.1 .*DOWN \(nothing answered' "${output}"
}

@test "spark-verify: --tolerate-unreachable lets a counted outage pass" {
  # One box answers, one is dead, so the mixed summary carries all four counters and
  # the exit code turns on the allowance alone.
  local scratch map
  scratch="$(scratch_checkout)"
  map="${scratch}/curl-map"
  printf '10.0.0.1:\t%s\n' "$(spark_ok_body 0)" >"${map}"

  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 STUB_CURL_OUT_MAP="${map}" \
    bash "${SCRIPT}" --no-tests 10.0.0.1 10.0.0.2
  [ "${status}" -eq 1 ]
  assert_match "the summary counts down beside unreachable" 'summary: 2 of 2 host\(s\) checked \(1 unreachable, 1 down, 0 expected down\) and 0 failed' "${output}"
  assert_match "the dead box is named" 'FAIL: 1 box\(es\) answered nothing on :8888 and are DOWN \(10\.0\.0\.2\)' "${output}"

  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 STUB_CURL_OUT_MAP="${map}" \
    bash "${SCRIPT}" --no-tests --tolerate-unreachable 1 10.0.0.1 10.0.0.2
  [ "${status}" -eq 0 ]
  assert_not_match "the tolerated box is not called a failure" 'FAIL: .*are DOWN' "${output}"
  assert_match "the counter still reports it down" '1 unreachable, 1 down, 0 expected down' "${output}"
  assert_contains_file "and the per-host object still reads DOWN" "${scratch}/sparks/10.0.0.2.jsonl" '"verdict":"DOWN"'
}

@test "spark-verify: --tolerate-unreachable refuses a non-number before any probe" {
  local scratch
  scratch="$(scratch_checkout)"
  run --separate-stderr env REPO_ROOT="${scratch}" bash "${SCRIPT}" \
    --tolerate-unreachable two 10.0.0.1
  [ "${status}" -eq 1 ]
  assert_match "the flag is named" 'tolerate-unreachable needs a whole number of hosts' "${stderr}"
  [ "$(stub_log_count curl)" -eq 0 ]
  [ "$(stub_log_count ssh)" -eq 0 ]
}

@test "spark-verify: the shipped placeholder trio is still a not-yet skip at exit 0" {
  # No .env, no SPARK_HOSTS, no argument: every name is one .env.sample ships, none
  # of them resolves, and nothing routes to them, so an unanswered probe there is
  # "not configured yet" rather than traffic failing over, and it stays green.
  local scratch
  scratch="$(scratch_checkout)"
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --no-tests
  [ "${status}" -eq 0 ]
  assert_match "the placeholder trio is the fleet" 'checking the placeholder trio spark-1\.lan spark-2\.lan spark-3\.lan' "${output}"
  assert_match "the note calls it a not-yet state" 'so the exit code stays 0' "${output}"
  assert_match "the verdict says why" 'is a shipped spark-<n>\.lan placeholder, not an address' "${output}"
  assert_contains_file "the box reads as a skip, not a down" "${scratch}/sparks/spark-1.lan.jsonl" '"verdict":"SKIP"'
}

@test "spark-verify: the DOWN line names the box and the two probes that came back empty" {
  # The verdict has to be actionable from the one line the operator is reading: which
  # box, and which probe drew the blank. The model port is where the proxy sends
  # traffic and ssh is the second, independent observation, so a DOWN that names
  # neither cannot be told apart from a port somebody retuned. --port is deliberately
  # not the shipped 8888 here: the line has to name the port this run dialled, and the
  # stub's log is the record of what it actually dialled.
  local scratch
  scratch="$(scratch_checkout)"
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --no-tests --port 9999 10.0.0.1
  [ "${status}" -eq 1 ]
  assert_match "the verdict names the box" '10\.0\.0\.1 .*DOWN' "${output}"
  assert_match "the verdict names the model port that did not answer" \
    'nothing answered on :9999' "${output}"
  assert_match "the verdict names the ssh probe that never opened" \
    'no ssh session opened either' "${output}"
  assert_match "and quotes ssh's own first complaint" 'ssh: stub failure' "${output}"
  assert_match "the announced probe is the one that ran" \
    '^-> probing http://10\.0\.0\.1:9999$' "${output}"
  assert_match "the FAIL line carries the box and the port together" \
    'FAIL: 1 box\(es\) answered nothing on :9999 and are DOWN \(10\.0\.0\.1\)' "${output}"
  [[ "$(stub_log_last curl)" == "curl -fsS -m 5 http://10.0.0.1:9999/health" ]]
  assert_contains_file "the per-host object is the same verdict" \
    "${scratch}/sparks/10.0.0.1.jsonl" '"verdict":"DOWN"'
}

@test "spark-verify: --expect-down is the documented way to assert an intended outage" {
  # What makes a DOWN verdict safe to act on is that the planned-outage escape is
  # findable without reading the script: --help prints the script's own header, and the
  # FAIL block of a run that just failed points at the same flag and spells the command.
  local scratch
  scratch="$(scratch_checkout)"

  run --separate-stderr env REPO_ROOT="${REPO_ROOT}" bash "${SCRIPT}" --help
  [ "${status}" -eq 0 ]
  assert_match "the help names the flag" '--expect-down <host>' "${output}"
  assert_match "the help calls it the outage taken on purpose" 'on purpose' "${output}"
  assert_match "and says the box is skipped rather than failed" 'skipped, not failed' "${output}"

  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --no-tests 10.0.0.1
  [ "${status}" -eq 1 ]
  assert_match "a failing run points at the documented flag" 'took one out on purpose' "${output}"
  assert_match "and hands over the exact invocation" \
    'spark-verify -- --no-tests --expect-down <host>' "${output}"
  assert_match "with the unnamed allowance named beside it" \
    'allow N unnamed with --tolerate-unreachable' "${output}"
}
