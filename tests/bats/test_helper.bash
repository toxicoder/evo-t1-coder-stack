# shellcheck shell=bash
#
# ## test_helper.bash — BATS support shared by tests/bats/*.bats (sourced; never
# executed)
#
# Invariants:
#   - Every helper here derives its paths from BATS_TEST_DIRNAME /
#     BATS_TEST_TMPDIR or from its arguments. No helper depends on the cwd of
#     the caller, and none hardcodes a machine path (the /repo fallback below
#     is a documented convention, not a requirement of the host).
#   - PATH-stubbed tools stay stubs: the stub copies and the command log are
#     per-test scratch under BATS_TEST_TMPDIR, so one test's argv log never
#     leaks into the next test. Real docker/ssh/curl only ever run in the
#     guarded integration tier, which must skip (not fail) when the real tool
#     or daemon is absent.
#
# Usage (top of a .bats file):
#   load 'test_helper'
#   setup() { use_stubs docker ssh; }

# shellcheck source=../test_helpers.sh disable=SC1091
source "${BATS_TEST_DIRNAME?}/../test_helpers.sh"

# Where the deterministic tool stubs live (override for unusual runtimes).
STUB_BIN_DIR="${STUB_BIN_DIR:-${BATS_TEST_DIRNAME?}/tool_stubs}"

# bats_canonical_repo_root — print the repo root for this run: the nearest
# ancestor of the cwd holding docker-compose.yml, then the same probe under
# /repo (the Bazel runfiles convention). Non-zero when neither matches.
bats_canonical_repo_root() {
  local dir="${PWD}"
  while [ -n "${dir}" ] && [ "${dir}" != "/" ]; do
    if [ -f "${dir}/docker-compose.yml" ]; then
      printf '%s' "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  if [ -f "/repo/docker-compose.yml" ]; then
    printf '%s' "/repo"
    return 0
  fi
  return 1
}

# make_scratch — print a fresh per-test scratch directory (BATS removes the
# BATS_TEST_TMPDIR tree after each test).
make_scratch() {
  local dir
  dir="$(mktemp -d "${BATS_TEST_TMPDIR?}/scratch.XXXXXX")"
  chmod 755 "${dir}"
  printf '%s' "${dir}"
}

# stub_bin <tool...> — copy each named tool's stub from STUB_BIN_DIR into a
# per-test bin/ directory, make it executable, and print that directory. The
# copy-plus-chmod (rather than symlinks or direct PATH use) is load-bearing:
# the Bazel sandbox and some tar extractions strip the exec bit.
stub_bin() {
  local tool bin
  bin="${BATS_TEST_TMPDIR?}/bin"
  mkdir -p "${bin}"
  for tool in "$@"; do
    if [ ! -f "${STUB_BIN_DIR?}/${tool}" ]; then
      printf 'FAIL: stub_bin: no stub for %s under %s\n' "${tool}" "${STUB_BIN_DIR}" >&2
      return 1
    fi
    cp "${STUB_BIN_DIR}/${tool}" "${bin}/${tool}"
    chmod 755 "${bin}/${tool}"
  done
  printf '%s' "${bin}"
}

# with_path <dir...> — print PATH with the given directories prepended.
with_path() {
  local d out=""
  for d in "$@"; do
    out="${out:+${out}:}${d}"
  done
  printf '%s' "${out:+${out}:}${PATH}"
}

# use_stubs <tool...> — one-stop shadowing: copy the stubs, point STUB_LOG at
# a fresh per-test log directory, and shadow PATH. Inside a @test body the
# PATH change is test-local; use_stubs returns non-zero when a stub is missing.
use_stubs() {
  local bin
  bin="$(stub_bin "$@")" || return 1
  export STUB_LOG="${BATS_TEST_TMPDIR?}/stub-logs"
  mkdir -p "${STUB_LOG}"
  PATH="${bin}:${PATH}"
  export PATH
}

# real_bin <tool> — print <tool> resolved with this test's stub bin/ removed
# from PATH (empty when only the stub would answer). The integration-tier gate:
#   if [ -z "$(real_bin terraform)" ]; then skip "terraform not installed"; fi
real_bin() {
  local tool="$1" stripped
  stripped="$(printf '%s' "${PATH}" | tr ':' '\n' | grep -vxF "${BATS_TEST_TMPDIR?}/bin" | paste -sd: -)"
  if [ -z "${stripped}" ]; then
    return 1
  fi
  PATH="${stripped}" command -v "${tool}" 2>/dev/null
}

# stub_log <tool> — print the full argv log recorded for <tool> this test.
stub_log() {
  if [ -f "${STUB_LOG:-}/${1}.log" ]; then
    cat "${STUB_LOG}/${1}.log"
  fi
}

# stub_log_last <tool> — print the last argv line recorded for <tool>.
stub_log_last() {
  if [ -f "${STUB_LOG:-}/${1}.log" ]; then
    tail -n 1 "${STUB_LOG}/${1}.log"
  fi
}

# stub_log_count <tool> — print how many invocations <tool> recorded.
stub_log_count() {
  if [ -f "${STUB_LOG:-}/${1}.log" ]; then
    wc -l <"${STUB_LOG}/${1}.log" | tr -d ' '
  else
    printf '0'
  fi
}
