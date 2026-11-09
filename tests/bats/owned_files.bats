#!/usr/bin/env bats
#
# ## owned_files.bats - hermetic coverage for the tracked-file ownership gate
#
# tests/owned_files_check.py decides, per tracked file, whether a Bazel target owns it,
# whether it is Bazel's own control plane, or whether the ledger excuses it. What is
# worth pinning is the five ways that decision has most often lied: a root-package label
# mapped as `/file` so almost the whole tree reads as unowned; ledger files counted as
# target-owned so the buckets stop summing to the tracked count; a reasonless ledger line
# excusing a file it never justified; a deletion leaving a stale claim behind; and a
# failed query reported as "nothing is owned", which buries a real graph in UNOWNED
# lines. Each of those gets an asserting test below.
#
# Usage: bazelisk test //tests:bats_owned_files_test   (from any cwd)
# Safety: bazelisk and git are per-test fakes written into the test's own bin
# directory, so no real Bazel is invoked (a Bazel test sandbox has no MODULE.bazel
# in its runfiles, so a real query could not analyze), no daemon runs, and nothing
# outside a scratch directory is written. The one runner-level test reads the real
# checkout and writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CHECKER=""
RUNNER=""
ROOT=""
LEDGER=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CHECKER="${REPO_ROOT}/tests/owned_files_check.py"
  RUNNER="${REPO_ROOT}/tests/owned_files.sh"
  [[ -f ${CHECKER} ]] || skip "tests/owned_files_check.py is not in the tree"
  ROOT="$(make_scratch)/repo"
  LEDGER="${ROOT}/unowned-files.txt"
  mkdir -p "${ROOT}"
  : >"${ROOT}/docker-compose.yml"
}

# fake_git <paths...> - declare the tracked set. The stub git below answers
# `ls-files -z` from this file, so a test states the tracked set outright instead of
# building a repository to imply it.
fake_git() {
  local f="${BATS_TEST_TMPDIR?}/tracked"
  : >"${f}"
  local path
  for path in "$@"; do
    printf '%s\n' "${path}" >>"${f}"
  done
  export FAKE_TRACKED="${f}"
}

# fake_bazelisk <labels...> - declare what the graph owns. The stub answers `query`
# from this file. An empty call models a graph that loaded and declared nothing,
# which the program must accept; STUB_QUERY_FAIL models the query itself failing,
# which it must not read as an empty owned set.
fake_bazelisk() {
  local f="${BATS_TEST_TMPDIR?}/labels"
  : >"${f}"
  local label
  for label in "$@"; do
    printf '%s\n' "${label}" >>"${f}"
  done
  export FAKE_LABELS="${f}"
}

# use_fake_tools - write the two stubs and shadow PATH, so neither real tool is
# reached. The stubs read the two files above rather than baking the answer into
# argv: a path list built by printf quoting is how this suite once produced a "git"
# that bash could not execute.
use_fake_tools() {
  local bin="${BATS_TEST_TMPDIR?}/bin"
  mkdir -p "${bin}"
  export STUB_LOG="${BATS_TEST_TMPDIR?}/stub-logs"
  mkdir -p "${STUB_LOG}"

  cat >"${bin}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -u
[ -n "${STUB_LOG:-}" ] && printf 'git %s\n' "$*" >>"${STUB_LOG}/git.log"
[ "${1:-}" = "ls-files" ] || exit 0
shift
target=""
while [ $# -gt 0 ]; do
  case "$1" in
    -*) ;;
    *) target="$1" ;;
  esac
  shift
done
if [ -n "${target}" ]; then
  # `ls-files --error-unmatch -- <path>` is git's "is this tracked?" question, which
  # the program asks about the ledger. STUB_LEDGER_UNTRACKED is the .gitignore hazard.
  [ -n "${STUB_LEDGER_UNTRACKED:-}" ] && exit 1
  exit 0
fi
tr '\n' '\0' <"${FAKE_TRACKED:?fake_git was not called}"
FAKE_GIT
  chmod 755 "${bin}/git"

  cat >"${bin}/bazelisk" <<'FAKE_BAZELISK'
#!/usr/bin/env bash
set -u
[ -n "${STUB_LOG:-}" ] && printf 'bazelisk %s\n' "$*" >>"${STUB_LOG}/bazelisk.log"
[ "${1:-}" = "query" ] || exit 0
if [ -n "${STUB_QUERY_FAIL:-}" ]; then
  printf 'ERROR: no such package\n' >&2
  exit 1
fi
cat "${FAKE_LABELS:?fake_bazelisk was not called}"
FAKE_BAZELISK
  chmod 755 "${bin}/bazelisk"

  PATH="${bin}:${PATH}"
  export PATH
}

# check <args...> - run the program over the fixture root.
check() {
  run --separate-stderr python3 "${CHECKER}" --root "${ROOT}" --ledger "${LEDGER}" "$@"
}

@test "a tree where every file is owned passes and the buckets sum to the tracked count" {
  fake_git README.md scripts/run.sh
  fake_bazelisk '//:README.md' '//scripts:run.sh'
  use_fake_tools
  check
  [[ ${status} -eq 0 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "one tracked, one owned" \
    "summary: 2 tracked | 2 target-owned | 0 control-plane | 0 ledger-excluded (reasoned) | 0 unowned | 0 stale ledger entries" \
    "${lines[0]}"
}

@test "a root-package label is a path, not a leading slash" {
  # The classic bug: mapping //:file by replacing ':' with '/' yields '/file', so every
  # root file lands in the unowned bucket. This test is red under that mapping.
  fake_git docker-compose.yml
  fake_bazelisk '//:docker-compose.yml'
  use_fake_tools
  check
  [[ ${status} -eq 0 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "the root file was owned" "1" "$(grep -c 'target-owned' <<<"${lines[0]}")"
  assert_not_match "the report named it unowned" "UNOWNED" "${output}"
}

@test "a file no target owns is reported and exits 1" {
  fake_git README.md orphan.txt
  fake_bazelisk '//:README.md'
  use_fake_tools
  check
  [[ ${status} -eq 1 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "one finding, one owned" \
    "summary: 2 tracked | 1 target-owned | 0 control-plane | 0 ledger-excluded (reasoned) | 1 unowned | 0 stale ledger entries" \
    "${lines[1]}"
  assert_eq "the finding named the file" "UNOWNED orphan.txt  (no target owns it and no ledger entry covers it)" "${lines[0]}"
}

@test "a ledger entry with a reason excuses the file" {
  fake_git README.md Makefile
  fake_bazelisk '//:README.md'
  printf 'Makefile\tshim that forwards to //:targets\n' >"${LEDGER}"
  use_fake_tools
  check
  [[ ${status} -eq 0 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "the file was excluded" \
    "summary: 2 tracked | 1 target-owned | 0 control-plane | 1 ledger-excluded (reasoned) | 0 unowned | 0 stale ledger entries" \
    "${lines[0]}"
}

@test "a ledger entry with no reason is a finding, not an exemption" {
  fake_git Makefile
  fake_bazelisk
  printf 'Makefile\n' >"${LEDGER}"
  use_fake_tools
  check
  [[ ${status} -eq 1 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "the missing reason was named" "UNOWNED Makefile  (ledger entry carries no reason)" "${lines[0]}"
}

@test "a stale ledger entry is counted, and only --strict-ledger fails on it" {
  fake_git README.md
  fake_bazelisk '//:README.md'
  printf 'gone.txt\tdeleted with its target\n' >"${LEDGER}"
  use_fake_tools

  check
  [[ ${status} -eq 0 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "the stale entry was reported" "1" "$(grep -c ' 1 stale ledger entries' <<<"${output}")"

  check --strict-ledger
  [[ ${status} -eq 1 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "strict mode failed the stale claim" "UNOWNED gone.txt  (ledger entry matches nothing (stale))" "${lines[0]}"
}

@test "Bazel's own control plane is exempt without a ledger entry" {
  fake_git .bazelrc .bazelversion MODULE.bazel BUILD.bazel docs/BUILD.bazel
  fake_bazelisk
  use_fake_tools
  check
  [[ ${status} -eq 0 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "all five were control plane" \
    "summary: 5 tracked | 0 target-owned | 5 control-plane | 0 ledger-excluded (reasoned) | 0 unowned | 0 stale ledger entries" \
    "${lines[0]}"
}

@test "a directory .bazelignore names is exempt too" {
  printf '# issued on the host\nproxy/certs/\n' >"${ROOT}/.bazelignore"
  fake_git proxy/certs/stack.crt proxy/certs/stack.key
  fake_bazelisk
  use_fake_tools
  check
  [[ ${status} -eq 0 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "both certs were control plane" \
    "summary: 2 tracked | 0 target-owned | 2 control-plane | 0 ledger-excluded (reasoned) | 0 unowned | 0 stale ledger entries" \
    "${lines[0]}"
}

@test "a ledger glob covers a whole directory" {
  fake_git .vscode/tasks.json .vscode/launch.json
  fake_bazelisk
  printf '.vscode/*\teditor convenience, no build meaning\n' >"${LEDGER}"
  use_fake_tools
  check
  [[ ${status} -eq 0 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "both files were excluded" \
    "summary: 2 tracked | 0 target-owned | 0 control-plane | 2 ledger-excluded (reasoned) | 0 unowned | 0 stale ledger entries" \
    "${lines[0]}"
}

@test "a query that failed is an environment error, never an empty owned set" {
  fake_git README.md
  fake_bazelisk
  use_fake_tools
  STUB_QUERY_FAIL=1 check
  [[ ${status} -eq 2 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  # The program echoes Bazel's own ERROR line before its verdict, so the assertion
  # is that its sentence is present rather than that it is the only line.
  [[ "${stderr}" == *"error: could not enumerate the owned set; is bazelisk on PATH?"* ]]
  assert_not_match "no UNOWNED flood followed the failed query" "UNOWNED" "${output}"
}

@test "a ledger that git does not track is refused, never obeyed" {
  # The regression this pins: the first ledger here was named bazel-unowned.txt, and
  # .gitignore's `/bazel-*` line -- written for Bazel's convenience symlinks -- matched
  # it. The gate read a file that was never in the repo, applied its exemptions to
  # whoever ran it locally, and told CI the tree was clean.
  fake_git README.md Makefile
  fake_bazelisk '//:README.md'
  printf 'Makefile\tshim that forwards to //:targets\n' >"${LEDGER}"
  use_fake_tools
  STUB_LEDGER_UNTRACKED=1 check
  [[ ${status} -eq 1 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  [[ "${stderr}" == *"is not tracked by git"* ]]
  assert_not_match "the hidden ledger excused nothing" "ledger-excluded" "${output}"
}

@test "--json keeps stdout a bare object a machine can read" {
  fake_git README.md orphan.txt
  fake_bazelisk '//:README.md'
  use_fake_tools
  check --json
  [[ ${status} -eq 1 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "stdout parsed as JSON" "orphan.txt" "$(python3 -c '
import json,sys
print(json.loads(sys.stdin.read())["unowned"][0]["path"])' <<<"${output}")"
  assert_eq "the counts came back too" "2" "$(python3 -c '
import json,sys
print(json.loads(sys.stdin.read())["tracked"])' <<<"${output}")"
}

@test "the audit expression is the whole graph, asked exactly once" {
  fake_git README.md
  fake_bazelisk '//:README.md'
  use_fake_tools
  check
  [[ ${status} -eq 0 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "one query produced the owned set" "1" "$(stub_log_count bazelisk)"
  [[ "$(stub_log_last bazelisk)" == *"kind('source file', deps(//...))"* ]]
}

@test "the runner forwards argv and honours EVO_T1_UNOWNED_LEDGER" {
  [[ -f ${RUNNER} ]] || skip "tests/owned_files.sh is not in the tree"
  fake_git README.md
  fake_bazelisk '//:README.md'
  use_fake_tools
  EVO_T1_UNOWNED_LEDGER="${LEDGER}" run --separate-stderr bash "${RUNNER}" --json
  [[ ${status} -eq 0 ]] || { printf 'stderr: %s\n' "${stderr}"; false; }
  assert_eq "the forwarded --json produced an object" "README.md" \
    "$(python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
print("README.md" if d["unowned"]==[] and d["tracked"]==1 else "unexpected")' <<<"${output}")"
}
