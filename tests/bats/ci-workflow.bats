#!/usr/bin/env bats
#
# ## ci-workflow.bats — CI runs the golden image, not a runner toolchain.
#
# The merge gate is images/dev/Dockerfile docker-run as the host uid:gid.
# These tests lock that shape so a later change cannot slip back to
# jobs.*.container, actions/setup-node, or ./.github/actions/setup-bazel on
# the bazel/docs jobs.
#
# Usage: bazelisk test //tests:bats_ci_workflow_test   (from any cwd)
# Safety: reads .github/workflows/ci.yml; writes nothing.

bats_require_minimum_version 1.5.0

# shellcheck source=/dev/null
load 'test_helper'

REPO_ROOT=""
CI_YML=""

# ci_workflow_root — print the checkout that holds .github/workflows/ci.yml.
# Bazel runfiles may only carry the files //:ci_workflows lists, so walk from
# the runfiles copy to the real checkout the way ci-lint-tools.bats does.
ci_workflow_root() {
  local candidate real dir
  for candidate in "${TEST_SRCDIR:-}/_main" "${REPO_ROOT:-}" "$(bats_canonical_repo_root || true)"; do
    if [ -n "${candidate}" ] && [ -f "${candidate}/.github/workflows/ci.yml" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
    if [ -n "${candidate}" ] && [ -f "${candidate}/docker-compose.yml" ]; then
      real="$(readlink -f "${candidate}/docker-compose.yml" 2>/dev/null ||
        realpath "${candidate}/docker-compose.yml" 2>/dev/null ||
        printf '%s' "${candidate}/docker-compose.yml")"
      dir="$(cd "$(dirname "${real}")" && pwd)"
      if [ -f "${dir}/.github/workflows/ci.yml" ]; then
        printf '%s' "${dir}"
        return 0
      fi
    fi
  done
  dir="$(cd "${BATS_TEST_DIRNAME}" && pwd)"
  while [ -n "${dir}" ] && [ "${dir}" != "/" ]; do
    if [ -f "${dir}/.github/workflows/ci.yml" ]; then
      printf '%s' "${dir}"
      return 0
    fi
    dir="$(dirname "${dir}")"
  done
  return 1
}

# ci_refute_line <label> <regex> — fail when ci.yml has a matching line.
ci_refute_line() {
  if grep -Eq -- "$2" "${CI_YML}"; then
    printf 'FAIL: %s: %s matches /%s/\n' "$1" "${CI_YML}" "$2" >&2
    return 1
  fi
}

setup() {
  REPO_ROOT="$(ci_workflow_root)" || skip "cannot locate .github/workflows/ci.yml"
  CI_YML="${REPO_ROOT}/.github/workflows/ci.yml"
  [[ -f ${CI_YML} ]] || skip "ci.yml is not in the tree"
}

@test "ci workflow: both jobs docker-run the golden image as root" {
  assert_contains_file "buildx" "${CI_YML}" 'docker/setup-buildx-action'
  assert_contains_file "build context" "${CI_YML}" 'context: images/dev'
  assert_contains_file "dockerfile" "${CI_YML}" 'file: images/dev/Dockerfile'
  assert_contains_file "local tag" "${CI_YML}" 'evo-t1-dev:latest'
  if ! grep -Fq 'docker run --rm --user "$(id -u):$(id -g)"' "${CI_YML}"; then
    printf 'FAIL: docker run as host uid missing from %s\n' "${CI_YML}" >&2
    return 1
  fi
  assert_contains_file "validate inner" "${CI_YML}" 'VALIDATE_INNER=1 bazelisk run //:validate'
  assert_contains_file "docs npm in image" "${CI_YML}" 'npm ci --legacy-peer-deps'
  assert_contains_file "packages write" "${CI_YML}" 'packages: write'
}

@test "ci workflow: no Actions container key and no runner toolchain installers" {
  ci_refute_line "jobs container key" '^[[:space:]]+container:'
  ci_refute_line "setup-bazel composite" 'uses: \./\.github/actions/setup-bazel'
  ci_refute_line "setup-node" 'uses: actions/setup-node'
  ci_refute_line "install-lint-tools" 'install-lint-tools\.sh'
}

@test "ci workflow: GHCR publish is main-only and only the bazel job pushes" {
  assert_contains_file "login gated to main push" "${CI_YML}" \
    "if: github.event_name == 'push' && github.ref == 'refs/heads/main'"
  if ! grep -Fq 'push: ${{ github.event_name == '\''push'\'' && github.ref == '\''refs/heads/main'\'' }}' "${CI_YML}"; then
    printf 'FAIL: bazel job push expression missing from %s\n' "${CI_YML}" >&2
    return 1
  fi
  assert_contains_file "docs job never pushes" "${CI_YML}" 'push: false'
  # login-action appears once (bazel job); docs job loads the cache hit only.
  local logins
  logins="$(grep -c 'docker/login-action' "${CI_YML}")"
  [ "${logins}" -eq 1 ]
}
