#!/usr/bin/env bats
#
# ## spark-verify.bats - hermetic coverage for scripts/spark-verify.sh.
#
# The entry script is the fleet's drift check; scripts/lib/probes/spark-verify.sh
# (the remote half) has its own suite in probes.bats, and the pure helpers this
# file also exercises live beside these cases in entry-fns.bats. What is pinned
# here is the policy the operator reads: a box that answers nothing is a skip
# with an exit of 0, the ssh session's own first complaint is what gets quoted,
# --json keeps stdout to one object per host, and a bad flag is refused before
# any probe leaves the box.
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

@test "spark-verify: a box that answers nothing is a skip and still exits 0" {
  local scratch
  scratch="$(scratch_checkout)"
  # The curl stub's default answer is an empty body with exit 22 (nothing
  # answered) and the ssh stub refuses with one stderr line, which is what the
  # caller quotes through first_line.
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --no-tests 10.0.0.1
  [ "${status}" -eq 0 ]
  assert_match "the host is named as a section" '^== host 10\.0\.0\.1 ==$' "${output}"
  assert_match "the http probe is announced" '^-> probing http://10\.0\.0\.1:8888$' "${output}"
  assert_match "ssh's own first line is quoted as the note" 'ssh: stub failure' "${output}"
  assert_match "the unreachable summary" 'summary: no Spark answered on :8888' "${output}"
  assert_match "the note calls it a not-yet state" 'so the exit code stays 0' "${output}"
  assert_contains_file "the per-host verdict was written" "${scratch}/sparks/10.0.0.1.jsonl" '"verdict":"SKIP"'
  [[ "$(stub_log_last curl)" == "curl -fsS -m 5 http://10.0.0.1:8888/health" ]]
}

@test "spark-verify: --json keeps stdout to one object per host" {
  local scratch
  scratch="$(scratch_checkout)"
  run --separate-stderr env REPO_ROOT="${scratch}" STUB_SSH_RC=1 \
    bash "${SCRIPT}" --json --no-tests 10.0.0.1
  [ "${status}" -eq 0 ]
  [ "$(printf '%s\n' "${output}" | wc -l | tr -d ' ')" -eq 1 ]
  assert_match "one parseable object" '^\{"host":"10\.0\.0\.1","reachable":false,"verdict":"SKIP"' "${output}"
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
