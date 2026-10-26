#!/usr/bin/env bats
#
# ## ci-workflow.bats — CI runs the golden image, not a runner toolchain.
#
# The merge gate is images/dev/Dockerfile, run through scripts/test-in-image.sh
# as the host uid:gid. These tests lock that shape so a later change cannot
# slip back to an inlined docker run, jobs.*.container, actions/setup-node, or
# ./.github/actions/setup-bazel on the bazel/docs jobs.
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

@test "ci workflow: both jobs run the gates through test-in-image in the golden image" {
  assert_contains_file "buildx" "${CI_YML}" 'docker/setup-buildx-action'
  assert_contains_file "build context" "${CI_YML}" 'context: images/dev'
  assert_contains_file "dockerfile" "${CI_YML}" 'file: images/dev/Dockerfile'
  assert_contains_file "local tag" "${CI_YML}" 'evo-t1-dev:latest'
  assert_contains_file "gates via test-in-image" "${CI_YML}" '\./scripts/test-in-image\.sh'
  assert_contains_file "test-fast gate" "${CI_YML}" 'test //:test-fast --config=ci'
  assert_contains_file "lint gate" "${CI_YML}" 'test //:lint --config=ci --test_tag_filters=manual'
  assert_contains_file "validate inner" "${CI_YML}" 'VALIDATE_INNER=1 \./scripts/test-in-image\.sh -- run //:validate'
  assert_contains_file "docs typecheck and unit" "${CI_YML}" '//docs-site:typecheck //docs-site:unit --test_tag_filters=manual'
  assert_contains_file "docs nav test" "${CI_YML}" '//docs-site:nav_test'
  assert_contains_file "docs nav check" "${CI_YML}" '//docs-site:npm -- run nav:check'
  # The full gate has to run on GitHub too, not only in the pre-push hook, or a
  # contributor who skipped the hook (git push --no-verify) lands an unverified
  # tree on main.
  assert_contains_file "full gate" "${CI_YML}" 'test //:test-all --config=ci'
  ci_refute_line "inline docker run" 'docker run'
  ci_refute_line "inline npm ci" 'npm ci --legacy-peer-deps'
  ci_refute_line "test-fast is not manual-filtered" 'test-fast.*test_tag_filters'
  ci_refute_line "nav_test is not manual-filtered" 'nav_test.*test_tag_filters'
  assert_contains_file "packages write" "${CI_YML}" 'packages: write'

  local image_script="${REPO_ROOT}/scripts/test-in-image.sh"
  [[ -f ${image_script} ]] || skip "scripts/test-in-image.sh is not in the tree"
  assert_contains_file "docker run" "${image_script}" 'docker run --rm'
  assert_contains_file "host user" "${image_script}" '--user'
  assert_contains_file "USER env for Bazel" "${image_script}" '-e "USER='
  assert_contains_file "CI passed through" "${image_script}" '-e CI'
  assert_contains_file "add-host" "${image_script}" '--add-host=host.docker.internal:host-gateway'

  local deploy="${REPO_ROOT}/.github/workflows/deploy-docs.yml"
  [[ -f ${deploy} ]] || skip "deploy-docs.yml is not in the tree"
  assert_contains_file "docs alias script" "${deploy}" 'scripts/ci/docs-alias\.sh'
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
