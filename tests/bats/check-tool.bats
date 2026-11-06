#!/usr/bin/env bats
# shellcheck shell=bash
#
# ## check-tool.bats — the host-tool probe every lint runner starts with
#
# lints/check_tool.sh holds the two functions each lint runner calls before it
# lints anything: check_tool turns a CLI that is not on PATH into a local skip
# and a CI failure, and bazel_checkout_root lands the runner on a checkout
# whether Bazel handed it a runfiles tree or a plain working directory. A lint
# gate is only as honest as the first of them. A probe that fails open under CI
# lets //:lint go green having checked nothing, which is the hole
# scripts/setup-host.sh exists to close; a probe that resolves the wrong root
# makes every runner lint the harness instead of the stack. Both are driven here
# from the shipped file, so the bodies under test are the bodies the runners get.
#
# Usage: bazelisk test //tests:bats_check_tool_test   (from any cwd)
# Safety: hermetic. The tool it looks for is a per-test stub or a name no PATH
# holds; nothing is installed, no network is used, and nothing is written
# outside BATS_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
PROBE=""

# A tool name no PATH can hold, so the missing-tool branches answer the same way
# on a machine that has every linter installed and on one that has none.
ABSENT_TOOL="evo-t1-absent-lint"

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  PROBE="${REPO_ROOT}/lints/check_tool.sh"
  [ -f "${PROBE}" ]
  # The probe reads both flags, and GitHub Actions exports CI=true into every
  # suite. Each test states the strictness it is testing, so the ambient value
  # cannot decide a verdict.
  unset CI REQUIRE_LINT_TOOLS
  # shellcheck source=/dev/null
  source "${PROBE}"
}

# make_fake_tool <name> — write an executable stub into this test's bin/ and
# print that directory, for PATH to pick up. Written per-test because the Bazel
# sandbox strips the exec bit off a shared copy.
make_fake_tool() {
  local name="$1" bin="${BATS_TEST_TMPDIR?}/bin"
  mkdir -p "${bin}"
  printf '#!/bin/sh\nexit 0\n' >"${bin}/${name}"
  chmod 755 "${bin}/${name}"
  printf '%s' "${bin}"
}

@test 'check_tool passes a tool that is on PATH and prints nothing' {
  local bin out rc=0
  bin="$(make_fake_tool "${ABSENT_TOOL}")"
  PATH="$(with_path "${bin}")"
  export PATH
  out="$(check_tool "${ABSENT_TOOL}" "uv tool install it")" || rc=$?
  [ "${rc}" -eq 0 ]
  [ -z "${out}" ]
}

@test 'check_tool skips a missing tool and returns 0 when nothing is strict' {
  local out rc=0
  out="$(check_tool "${ABSENT_TOOL}" "uv tool install it")" || rc=$?
  [ "${rc}" -eq 0 ]
  assert_match "the skip names the tool" '^evo-t1-absent-lint missing - skipping' "${out}"
  assert_match "the skip carries the install hint" 'uv tool install it' "${out}"
}

@test 'check_tool fails a missing tool when CI is true' {
  local out rc=0
  CI=true
  export CI
  out="$(check_tool "${ABSENT_TOOL}" "uv tool install it" 2>&1)" || rc=$?
  [ "${rc}" -eq 1 ]
  assert_match "the error says the tool is required in CI" 'missing - required in CI' "${out}"
  assert_match "the error carries the install hint" 'uv tool install it' "${out}"
}

@test 'check_tool fails a missing tool when REQUIRE_LINT_TOOLS is 1' {
  local out rc=0
  REQUIRE_LINT_TOOLS=1
  export REQUIRE_LINT_TOOLS
  out="$(check_tool "${ABSENT_TOOL}" "brew install it" 2>&1)" || rc=$?
  [ "${rc}" -eq 1 ]
  assert_match "the error says the tool is required" 'evo-t1-absent-lint missing - required in CI' "${out}"
  assert_match "the error names the remedy" 'brew install it' "${out}"
}

@test 'check_tool stays lenient unless the flag reads exactly true or 1' {
  local out rc=0
  CI=false
  export CI
  out="$(check_tool "${ABSENT_TOOL}")" || rc=$?
  [ "${rc}" -eq 0 ]
  assert_match "CI=false still skips" 'skipping' "${out}"
  unset CI
  REQUIRE_LINT_TOOLS=0
  export REQUIRE_LINT_TOOLS
  rc=0
  out="$(check_tool "${ABSENT_TOOL}")" || rc=$?
  [ "${rc}" -eq 0 ]
  assert_match "REQUIRE_LINT_TOOLS=0 still skips" 'skipping' "${out}"
}

@test 'check_tool supplies an install command when the runner passed no hint' {
  local out rc=0
  out="$(check_tool "${ABSENT_TOOL}")" || rc=$?
  [ "${rc}" -eq 0 ]
  assert_match "the default hint names the tool" 'install evo-t1-absent-lint' "${out}"
}

@test 'bazel_checkout_root answers BUILD_WORKSPACE_DIRECTORY when it is a directory' {
  local dir out
  dir="$(make_scratch)"
  BUILD_WORKSPACE_DIRECTORY="${dir}"
  export BUILD_WORKSPACE_DIRECTORY
  out="$(bazel_checkout_root)"
  [ "${out}" = "${dir}" ]
}

@test 'bazel_checkout_root ignores a BUILD_WORKSPACE_DIRECTORY that is not a directory' {
  local out
  BUILD_WORKSPACE_DIRECTORY="/nonexistent/evo-t1-runfiles/_main"
  export BUILD_WORKSPACE_DIRECTORY
  out="$(bazel_checkout_root)"
  assert_match "the answer is absolute" '^/' "${out}"
  [ -f "${out}/lints/check_tool.sh" ]
}

@test 'bazel_checkout_root resolves the probe directory with no Bazel env at all' {
  local out
  unset BUILD_WORKSPACE_DIRECTORY
  out="$(bazel_checkout_root)"
  assert_match "the answer is absolute" '^/' "${out}"
  [ -f "${out}/lints/check_tool.sh" ]
  [ -f "${out}/lints/run_shellcheck.sh" ]
}
