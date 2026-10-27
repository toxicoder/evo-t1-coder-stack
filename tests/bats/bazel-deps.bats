#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## bazel-deps.bats — the Bazel data maps match the sources that use them.
#
# scripts/BUILD.bazel and tests/BUILD.bazel carry the record of which repo file each
# target reads: _SCRIPT_LIBS / _SCRIPT_PAYLOAD / _SCRIPT_PAYLOAD_ALLOW for the CLI
# targets, _SUITE_PAYLOAD / _SUITE_PAYLOAD_ALLOW for the suites. tests/bazel_deps.py
# re-derives those maps from the shell and Bats sources and reports the drift both
# ways, so an automated reader can trust the BUILD files: a script that starts
# reading a payload its target does not declare, or a target that still ships a
# payload nothing opens, fails here. The first case is a startup failure under
# `bazel run` (the file is missing from runfiles) and the second is the bloat this
# refactor set out to remove, so both belong in the gate.
#
# The last two cases guard the map itself rather than its contents: a key list that
# stopped covering a script or a suite would let the first case pass vacuously, and
# an _ALLOW entry without its reason line is the escape hatch quietly widening.
#
# Usage: bazelisk test //tests:bats_bazel_deps_test   (from any cwd)
# Safety: reads the BUILD files, the scripts tree and the suite tree; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CHECKER=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  CHECKER="${REPO_ROOT}/tests/bazel_deps.py"
  # A gate that cannot find its own program has to say so: this suite declares
  # bazel_deps.py in _SUITE_PAYLOAD, so a missing file means that declaration broke,
  # and skipping here would leave the whole map unguarded.
  if [[ ! -f ${CHECKER} ]]; then
    printf 'FAIL: tests/bazel_deps.py is not in the runfiles of %s; _SUITE_PAYLOAD for bazel-deps.bats must declare it\n' \
      "${REPO_ROOT}" >&2
    return 1
  fi
}

# map_key_count <build-file> <map-name> - the number of keys in a literal Starlark dict.
map_key_count() {
  python3 - "${1}" "${2}" <<'PY'
import ast
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"^%s = (\{.*?^\})" % re.escape(sys.argv[2]), text, re.MULTILINE | re.DOTALL)
print(len(ast.literal_eval(match.group(1))) if match else -1)
PY
}

# unreasoned_allow_keys <build-file> - one line per _ALLOW key with no `#` reason above it.
unreasoned_allow_keys() {
  python3 - "${1}" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
for name in ("_SCRIPT_PAYLOAD_ALLOW", "_SUITE_PAYLOAD_ALLOW"):
    match = re.search(r"^%s = \{(.*?)^\}" % name, text, re.MULTILINE | re.DOTALL)
    if not match:
        continue
    body = match.group(1).splitlines()
    for index, line in enumerate(body):
        if not re.match(r'^\s+"[^"]+": \[$', line):
            continue
        above = body[index - 1].strip() if index else ""
        if not above.startswith("#"):
            print(line.strip())
PY
}

@test "bazel_deps: every map matches the sources that use it" {
  run python3 "${CHECKER}" --root "${REPO_ROOT}"
  [ "${status}" -eq 0 ] || {
    printf 'FAIL: the dependency gate reported:\n%s\n' "${output}" >&2
    return 1
  }
  assert_match "the whole gate ran" 'summary: 3 ok, 0 warnings, 0 failed' "${output}"
}

@test "bazel_deps: the scripts map keys every CLI in the package" {
  local scripts keyed
  # -L: under `bazelisk test` the sources arrive in runfiles as symlinks, and a plain
  # find -type f sees only the link and counts nothing.
  scripts="$(find -L "${REPO_ROOT}/scripts" -maxdepth 1 -name '*.sh' -type f | wc -l | tr -d '[:space:]')"
  keyed="$(map_key_count "${REPO_ROOT}/scripts/BUILD.bazel" "_SCRIPT_LIBS")"
  assert_eq "one _SCRIPT_LIBS key per scripts/*.sh" "${scripts}" "${keyed}"
  keyed="$(map_key_count "${REPO_ROOT}/scripts/BUILD.bazel" "_SCRIPT_PAYLOAD")"
  assert_eq "one _SCRIPT_PAYLOAD key per scripts/*.sh" "${scripts}" "${keyed}"
}

@test "bazel_deps: the suites map keys every suite file" {
  local suites keyed
  suites="$(find -L "${REPO_ROOT}/tests/bats" -maxdepth 1 -name '*.bats' -type f | wc -l | tr -d '[:space:]')"
  keyed="$(map_key_count "${REPO_ROOT}/tests/BUILD.bazel" "_SUITE_PAYLOAD")"
  assert_eq "one _SUITE_PAYLOAD key per tests/bats/*.bats" "${suites}" "${keyed}"
}

@test "bazel_deps: every _ALLOW entry carries its reason in the BUILD file" {
  local build unreasoned
  for build in "${REPO_ROOT}/scripts/BUILD.bazel" "${REPO_ROOT}/tests/BUILD.bazel"; do
    unreasoned="$(unreasoned_allow_keys "${build}")"
    if [[ -n ${unreasoned} ]]; then
      printf 'FAIL: %s has _ALLOW entries with no # reason above the key:\n%s\n' \
        "${build##*/}" "${unreasoned}" >&2
      return 1
    fi
  done
}
