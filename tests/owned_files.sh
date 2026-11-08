#!/usr/bin/env bash
#
# ## owned_files
#
# Fail unless every path `git ls-files` reports is a source or data file of some
# Bazel target, Bazel's own control plane, or listed in unowned-files.txt with a
# reason. This is the definition-of-done gate for the Bazelisk-first rule: a
# committed file that no target can open is invisible to //:test-fast and //:lint
# and reports no failure anywhere else.
#
# The owned set comes from `bazelisk query 'kind("source file", deps(//...))'`,
# which needs a reachable Bazel server. `bazel run` gives one (the same nested
# query //scripts:bazel-map runs), so the audit ingress is
# `bazelisk run //tests:owned_files_audit`. A `bazel test` action holds the server
# instead, so //tests:owned_files pins the logic against a stubbed Bazelisk and the
# hermetic unit suite in tests/python/test_owned_files_check.py covers the bucketing.
#
# Usage:
#   bazelisk run //tests:owned_files_audit            # the whole graph, in CI
#   bazelisk test //tests:bats_owned_files_test       # the hermetic logic check
#   bash tests/owned_files.sh [-- --json]             # from a host shell
#
# Exit codes: 0 clean, 1 findings, 2 the graph could not be enumerated.

set -euo pipefail

# shellcheck source=repo_root.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo_root.sh"
ROOT="$(tests_repo_root)"
cd "${ROOT}"

LEDGER="${EVO_T1_UNOWNED_LEDGER:-unowned-files.txt}"

# @function main
# Run the ownership check over the checkout and pass its exit status through.
# Globals:
#   ROOT, LEDGER
# Arguments:
#   None (extra argv is forwarded to the checker)
# Outputs:
#   One UNOWNED line per finding and the closing summary, on stdout
# Returns:
#   0 clean, 1 findings, 2 environment error
main() {
  python3 tests/owned_files_check.py \
    --root "${ROOT}" \
    --ledger "${LEDGER}" \
    --strict-ledger \
    "$@"
}

main "$@"
