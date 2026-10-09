#!/usr/bin/env bash
#
# ## bats_runner
#
# Hermetic Bats runner for Bazel sh_test. Locates bats-core and the suite via
# runfiles, then execs bats with REPO_ROOT pointing at the checkout.

set -euo pipefail

if [[ -n ${TEST_SRCDIR:-} ]]; then
  RUNFILES="${TEST_SRCDIR}"
else
  RUNFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# @function find_file
# Locate a runfiles path by name across Bazel candidate roots.
# Globals:
#   RUNFILES
# Arguments:
#   $1 - relative path to find
# Outputs:
#   Absolute path on stdout
# Returns:
#   0 on success; exits 1 otherwise
find_file() {
  local name="$1"
  local candidates=(
    "${RUNFILES}/_main/${name}"
    "${RUNFILES}/${name}"
    "${RUNFILES}/external/${name}"
    "${RUNFILES}/bats_core/${name}"
    "${RUNFILES}/_main/external/bats_core/${name}"
    "${RUNFILES}/+_repo_rules+bats_core/${name}"
    "${RUNFILES}/+_repo_rules+bats_core/bin/bats"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -e ${c} ]]; then
      echo "${c}"
      return 0
    fi
  done
  echo "ERROR: Could not locate ${name} in runfiles" >&2
  echo "RUNFILES=${RUNFILES}" >&2
  exit 1
}

# @function repo_root_from_marker
# Derive the repository root from a known marker file path.
# Globals:
#   None
# Arguments:
#   $1 - absolute marker file path
# Outputs:
#   Absolute repo root
# Returns:
#   0
repo_root_from_marker() {
  local marker="$1"
  local dir
  dir="$(dirname "${marker}")"
  case "${marker}" in
    */docker-compose.yml) (cd "${dir}" && pwd) ;;
    */scripts/bootstrap.sh) (cd "${dir}/.." && pwd) ;;
    *) (cd "${dir}" && pwd) ;;
  esac
}

BATS_BIN="$(find_file +_repo_rules+bats_core/bin/bats 2>/dev/null || find_file bats_core/bin/bats)"

REPO_ROOT_MARKER="$(
  find_file _main/docker-compose.yml 2>/dev/null ||
    find_file docker-compose.yml 2>/dev/null || true
)"

if [[ -n ${REPO_ROOT_MARKER} && -f ${REPO_ROOT_MARKER} ]]; then
  REPO_ROOT="$(repo_root_from_marker "${REPO_ROOT_MARKER}")"
else
  runner_real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  REPO_ROOT="$(cd "$(dirname "${runner_real}")/.." && pwd)"
fi
export REPO_ROOT
cd "${REPO_ROOT}"

BATS_HELPER="$(
  find_file _main/tests/bats/test_helper.bash 2>/dev/null ||
    find_file tests/bats/test_helper.bash 2>/dev/null || true
)"
if [[ -z ${BATS_HELPER} || ! -f ${BATS_HELPER} ]]; then
  echo "ERROR: Could not locate tests/bats/test_helper.bash in runfiles" >&2
  exit 1
fi
BATS_TEST_DIR="$(dirname "${BATS_HELPER}")"

BATS_TEST_FILES=()
if [[ $# -gt 0 ]]; then
  for name in "$@"; do
    case "${name}" in
      *.bats) BATS_TEST_FILES+=("${BATS_TEST_DIR}/${name}") ;;
      *) BATS_TEST_FILES+=("${BATS_TEST_DIR}/${name}.bats") ;;
    esac
  done
else
  BATS_TEST_FILES=("${BATS_TEST_DIR}"/*.bats)
fi

if [[ ! -e ${BATS_TEST_FILES[0]} ]]; then
  echo "ERROR: No .bats files found under ${BATS_TEST_DIR} (args: $*)" >&2
  exit 1
fi

exec "${BATS_BIN}" --print-output-on-failure "${BATS_TEST_FILES[@]}"
