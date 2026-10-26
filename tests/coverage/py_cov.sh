#!/usr/bin/env bash
#
# ## py_cov
#
# Measured coverage for the Python the stack ships: the scripts/lib helpers the
# operator CLIs shell out to, and the docs-site nav generator.
#
# It runs every unittest suite under coverage.py and fails below the floor, so
# "the helper has a test" means the interpreter reported the line executed.
#
# coverage.py is baked into the golden image (COVERAGE_VERSION in
# images/dev/tool-versions.env). A machine without it is told to run the gate in
# the image, which is what AGENTS.md prescribes for the gate anyway; it is never
# silently skipped, because a coverage gate that passes while measuring nothing
# is the failure mode this target exists to prevent.
#
# Usage:
#   bazelisk test //tests:py_coverage
#   bazelisk run //scripts:test-in-image -- -- test //tests:py_coverage
set -euo pipefail

# @function py_cov_repo_root
# Locate the checkout that holds the Python sources and their suites.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Absolute repository root on stdout
# Returns:
#   0 on success; returns 1 when no marker is present
py_cov_repo_root() {
  local here dir
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for dir in "${here}/../.." "${here}/.."; do
    if [[ -f ${dir}/docker-compose.yml ]]; then
      (cd "${dir}" && pwd)
      return 0
    fi
  done
  return 1
}

# @function py_cov_binary
# Print the coverage entry point, preferring the pinned tool.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Command prefix on stdout
# Returns:
#   0 when usable; 1 when coverage.py is absent
py_cov_binary() {
  if command -v coverage >/dev/null 2>&1; then
    printf 'coverage\n'
    return 0
  fi
  if python3 -c 'import coverage' >/dev/null 2>&1; then
    printf 'python3 -m coverage\n'
    return 0
  fi
  return 1
}

# @function main
# Run every Python suite under coverage and enforce the floor.
# Globals:
#   EVO_PY_COV_MIN, TEST_TMPDIR
# Arguments:
#   None
# Outputs:
#   Coverage table on stdout; guidance on stderr when the tool is missing
# Returns:
#   0 when the floor is met, 1 otherwise
main() {
  local root cov min here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(py_cov_repo_root)" || {
    echo "error: cannot locate the checkout" >&2
    return 1
  }
  cov="$(py_cov_binary)" || {
    echo "error: coverage.py is not installed" >&2
    echo "note: it ships in the golden image; run the gate there with" >&2
    echo "      bazelisk run //scripts:test-in-image -- -- test //tests:py_coverage" >&2
    return 1
  }

  min="${EVO_PY_COV_MIN:-100}"
  export COVERAGE_FILE="${TEST_TMPDIR:-/tmp}/evo-python.cov"
  rm -f "${COVERAGE_FILE}"

  echo "== python coverage =="
  echo "floor: ${min}% statements and branches"

  local -a suites=(
    "tests/python:test_*.py:."
    "docs-site:test_gen_nav.py:docs-site"
  )
  local entry start_dir pattern top
  for entry in "${suites[@]}"; do
    IFS=: read -r start_dir pattern top <<<"${entry}"
    if [[ ! -d ${root}/${start_dir} ]]; then
      echo "error: suite directory ${start_dir} is missing" >&2
      return 1
    fi
    # -L: under `bazelisk test` the sources arrive in runfiles as symlinks, and
    # a plain find -type f sees only the link and reports an empty suite.
    if ! find -L "${root}/${start_dir}" -name "${pattern}" -type f | grep -q .; then
      echo "error: no ${pattern} found under ${start_dir}" >&2
      return 1
    fi
    echo "-> coverage run: ${start_dir}/${pattern}"
    (cd "${root}" && ${cov} run --branch --append \
      -m unittest discover -s "${start_dir}" -p "${pattern}" -t "${top}")
  done

  # The report is decided by py_report.py against the list of modules the tree
  # actually ships, which coverage's own --include cannot do from here: it
  # resolves a relative pattern against the cwd, and under Bazel the cwd is the
  # runfiles tree while the recorded paths are the checkout's. That mismatch
  # prints "No data to report" and exits 0, which is a gate that passes on
  # nothing measured.
  echo "-> report"
  (cd "${root}" && ${cov} json -q -o "${TEST_TMPDIR:-/tmp}/evo-python.json") || return 1
  python3 "${here}/py_report.py" --json "${TEST_TMPDIR:-/tmp}/evo-python.json" \
    --root "${root}" --expect scripts/lib --expect docs-site/scripts --min "${min}"
  echo "ok: python coverage meets ${min}%"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
