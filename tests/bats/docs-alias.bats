#!/usr/bin/env bats
#
# ## docs-alias.bats — Pages alias for one git ref.
#
# main and master are latest. Anything else collapses to one URL segment.
# An empty result or a ".." segment is refused.
#
# Usage: bazelisk test //tests:bats_docs_alias_test
# Safety: reads scripts/ci/docs-alias.sh; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
SCRIPT=""

setup() {
  REPO_ROOT="$(bats_canonical_repo_root)" || skip "cannot locate the repo root (no docker-compose.yml marker)"
  SCRIPT="${REPO_ROOT}/scripts/ci/docs-alias.sh"
  [[ -f ${SCRIPT} ]] || skip "scripts/ci/docs-alias.sh is not in the tree"
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/scripts/lib/common.sh"
  load_shell_function "${SCRIPT}" docs_alias
}

@test "docs_alias: main and master publish as latest" {
  run --separate-stderr docs_alias main
  [ "${status}" -eq 0 ]
  [ "${output}" = "latest" ]

  run --separate-stderr docs_alias master
  [ "${status}" -eq 0 ]
  [ "${output}" = "latest" ]
}

@test "docs_alias: a feature ref collapses unsafe characters to one segment" {
  run --separate-stderr docs_alias feat/foo
  [ "${status}" -eq 0 ]
  [ "${output}" = "feat-foo" ]

  run --separate-stderr docs_alias "feat/foo bar"
  [ "${status}" -eq 0 ]
  [ "${output}" = "feat-foo-bar" ]
}

@test "docs_alias: an empty, dot-dot, or emptied alias is refused" {
  run --separate-stderr docs_alias ""
  [ "${status}" -ne 0 ]
  assert_match "empty ref" 'unusable alias' "${stderr}"

  run --separate-stderr docs_alias ".."
  [ "${status}" -ne 0 ]
  assert_match "dot-dot ref" 'unusable alias' "${stderr}"

  run --separate-stderr docs_alias "///"
  [ "${status}" -ne 0 ]
  assert_match "sanitized empty" 'unusable alias' "${stderr}"
}

@test "docs_alias: the script prints the alias and exits with the function status" {
  run --separate-stderr bash "${SCRIPT}" feat/foo
  [ "${status}" -eq 0 ]
  [ "${output}" = "feat-foo" ]

  run --separate-stderr bash "${SCRIPT}" ".."
  [ "${status}" -ne 0 ]
  assert_match "script refusal" 'unusable alias' "${stderr}"
}
