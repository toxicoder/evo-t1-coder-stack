#!/usr/bin/env bash
#
# ## repo_root
#
# Resolve the checkout root from bazel run, bazel test runfiles, or script path.

# @function tests_repo_root
# Print the repository root (the source tree, not bazel-bin).
# Globals:
#   BUILD_WORKSPACE_DIRECTORY, TEST_SRCDIR
# Arguments:
#   None
# Outputs:
#   Absolute repo root
# Returns:
#   0, or 1 when no marker exists
tests_repo_root() {
  local marker real here
  if [[ -n ${BUILD_WORKSPACE_DIRECTORY:-} && -f ${BUILD_WORKSPACE_DIRECTORY}/MODULE.bazel ]]; then
    echo "${BUILD_WORKSPACE_DIRECTORY}"
    return 0
  fi
  if [[ -n ${TEST_SRCDIR:-} && -f ${TEST_SRCDIR}/_main/docker-compose.yml ]]; then
    marker="${TEST_SRCDIR}/_main/docker-compose.yml"
    real="$(readlink -f "${marker}" 2>/dev/null || realpath "${marker}" 2>/dev/null || echo "${marker}")"
    echo "$(cd "$(dirname "${real}")" && pwd)"
    return 0
  fi
  local resolved="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  resolved="$(readlink -f "${resolved}" 2>/dev/null || echo "${resolved}")"
  here="$(cd "$(dirname "${resolved}")" && pwd)"
  if [[ -f ${here}/../MODULE.bazel ]]; then
    echo "$(cd "${here}/.." && pwd)"
    return 0
  fi
  if [[ -f ${here}/../docker-compose.yml ]]; then
    echo "$(cd "${here}/.." && pwd)"
    return 0
  fi
  echo "tests_repo_root: cannot locate the checkout" >&2
  return 1
}
