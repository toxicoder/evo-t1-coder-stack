#!/usr/bin/env bash
#
# ## shell_cov
#
# Report how much of the production shell code the Bats suite actually runs.
#
# The existing //tests:shell_inventory gate only proves a function NAME appears
# somewhere under tests/. That is a weak claim: a name inside a tool stub, a
# fixture, or a quoted grep pattern satisfies it while the function never runs.
# This target answers the stronger question by watching the functions execute.
#
# How it measures: tests/coverage/instrument.py builds a mirror of the checkout
# whose production .sh files carry one extra statement at the top of every
# function body, appending "<path>\t<function>" to $EVO_COV_LEDGER. Every other
# path a suite reads is a symlink back into the real tree, and the suites reach
# production code through ${REPO_ROOT} in all three of their access patterns
# (run the CLI, source the lib, load_shell_function), so pointing REPO_ROOT at
# the mirror instruments exactly the code under test and nothing else.
#
# bash xtrace was the obvious first attempt and was rejected on evidence: it
# traced bats-core itself, wrote 3.4 GB of log for one suite, and leaked trace
# lines into the stderr bats captures per test, which turned output-asserting
# suites red. The ledger measures less and breaks nothing.
#
# Usage:
#   bazelisk test //tests:shell_coverage
#   bash tests/coverage/shell_cov.sh [bats-suite-name ...]
#   EVO_COV_MIN_FUNCTIONS=90 bash tests/coverage/shell_cov.sh
set -euo pipefail

# @function cov_repo_root
# Locate the checkout that holds the Bats suites.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Absolute repository root on stdout
# Returns:
#   0 on success; returns 1 when no marker is present
cov_repo_root() {
  local here dir
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for dir in "${here}/../.." "${here}/.."; do
    if [[ -f ${dir}/docker-compose.yml && -d ${dir}/tests/bats ]]; then
      (cd "${dir}" && pwd)
      return 0
    fi
  done
  return 1
}

# @function main
# Build the mirror, run the suites against it, and print the coverage verdict.
# Globals:
#   EVO_COV_DIR, EVO_COV_MIN_FUNCTIONS, TEST_TMPDIR
# Arguments:
#   "$@" - optional bats suite names
# Outputs:
#   Runner output and the aggregator report on stdout
# Returns:
#   0 when every production function was reached, 1 otherwise
main() {
  local root runner ledger rc=0
  root="$(cov_repo_root)" || {
    echo "error: cannot locate the checkout" >&2
    return 1
  }
  runner="${root}/tests/bats_runner.sh"

  EVO_COV_DIR="${EVO_COV_DIR:-${TEST_TMPDIR:-/tmp}/evo-cov}"
  rm -rf "${EVO_COV_DIR}"
  mkdir -p "${EVO_COV_DIR}/mirror"
  ledger="${EVO_COV_DIR}/ledger.tsv"
  : >"${ledger}"

  echo "== shell coverage =="
  echo "work dir: ${EVO_COV_DIR}"
  echo "-> building the instrumented mirror"
  python3 "${root}/tests/coverage/instrument.py" \
    --root "${root}" --out "${EVO_COV_DIR}/mirror"

  export EVO_COV_MIRROR="${EVO_COV_DIR}/mirror"
  export EVO_COV_LEDGER="${ledger}"

  echo "-> running bats against the mirror"
  if [[ $# -gt 0 ]]; then
    (cd "${root}" && bash "${runner}" "$@") || rc=$?
  else
    (cd "${root}" && bash "${runner}") || rc=$?
  fi
  local marks
  marks="$(wc -l <"${ledger}" 2>/dev/null || echo 0)"
  echo "ok: ${marks} function invocations recorded"

  if [[ ${rc} -ne 0 ]]; then
    echo "error: the bats run failed; coverage of a red suite is not a verdict" >&2
    return "${rc}"
  fi

  python3 "${root}/tests/coverage/aggregate.py" \
    --root "${root}" --ledger "${ledger}"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
